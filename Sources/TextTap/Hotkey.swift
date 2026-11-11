import Cocoa

enum HotkeyEvent {
    case toggle         // Double tap, or the shortcut
    case holdBegan      // The modifier has been held past the hold threshold
    case holdEnded      // A held modifier was released
    case holdCancelled  // A held modifier became part of another shortcut
    case escape
}

/// Detects the dictation hotkey with a session event tap: a double tap or hold of a
/// modifier in double-tap mode, or a key binding in shortcut mode.
final class Hotkey {
    var config: HotkeyConfig
    /// Events are delivered on the main queue.
    var onEvent: (HotkeyEvent) -> Void = { _ in }
    /// Escape is swallowed and reported only while this returns true.
    var capturesEscape: () -> Bool = { false }
    /// Presses of the dictation modifier are ignored while this returns true.
    var isPaused: () -> Bool = { false }

    private static let holdThreshold: TimeInterval = 0.3
    private static let escapeKeyCode: UInt16 = 0x35

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keyIsDown = false
    private var usedAsCombo = false
    private var isHolding = false
    private var lastTap: Date?
    private var holdTimer: DispatchWorkItem?

    init(config: HotkeyConfig) {
        self.config = config
    }

    var isInstalled: Bool { tap != nil }

    /// Installs the event tap; this fails without Accessibility permission.
    @discardableResult
    func install() -> Bool {
        guard tap == nil else { return true }
        let events: [CGEventType] = [.flagsChanged, .keyDown, .keyUp]
        let mask = events.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                let hotkey = Unmanaged<Hotkey>.fromOpaque(refcon!).takeUnretainedValue()
                return hotkey.handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        return true
    }

    func uninstall() {
        reset()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        // macOS disables a tap that times out or is interrupted by user input.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            reset()
            return pass
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, keyCode == Self.escapeKeyCode, capturesEscape() {
            emit(.escape)
            return nil
        }

        switch config.mode {
        case .doubleTap:
            handleModifier(type, event.flags)
            return pass
        case .shortcut:
            return handleShortcut(type, keyCode, event.flags) ? nil : pass
        }
    }

    /// A press shorter than the hold threshold is a tap, and two taps toggle dictation.
    /// A longer press is push-to-talk. Any other key or modifier makes it a shortcut instead.
    private func handleModifier(_ type: CGEventType, _ flags: CGEventFlags) {
        let key = config.key.lowercased()
        guard let flag = Self.modifierFlags[key] else { return }

        if type == .keyDown {
            if keyIsDown {
                usedAsCombo = true
                cancelHold()
            }
            return
        }
        guard type == .flagsChanged else { return }

        let pressed: Bool = Self.deviceMasks[key].map { flags.rawValue & $0 != 0 } ?? flags.contains(flag)
        let otherModifiers = !flags.subtracting(flag)
            .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl]).isEmpty

        switch (pressed, keyIsDown) {
        case (true, false):
            // A stray press while transcribing must not count as the first of a double tap.
            guard !isPaused() else { return }
            keyIsDown = true
            usedAsCombo = otherModifiers
            if !usedAsCombo { scheduleHold() }

        case (true, true):
            if otherModifiers {
                usedAsCombo = true
                cancelHold()
            }

        case (false, true):
            keyIsDown = false
            cancelHold()
            defer {
                usedAsCombo = false
                isHolding = false
            }
            if usedAsCombo {
                if isHolding { emit(.holdCancelled) }
            } else if isHolding {
                emit(.holdEnded)
            } else if let lastTap, Date().timeIntervalSince(lastTap) < config.doubleTapInterval {
                self.lastTap = nil
                emit(.toggle)
            } else {
                lastTap = Date()
            }

        case (false, false):
            break
        }
    }

    private func handleShortcut(_ type: CGEventType, _ keyCode: UInt16, _ flags: CGEventFlags) -> Bool {
        guard type == .keyDown,
              let shortcut = Self.parse(config.shortcut),
              keyCode == shortcut.keyCode,
              flags.contains(shortcut.modifiers) else { return false }
        emit(.toggle)
        return true
    }

    private func scheduleHold() {
        cancelHold()
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.keyIsDown, !self.usedAsCombo else { return }
            self.isHolding = true
            self.lastTap = nil
            self.onEvent(.holdBegan)
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdThreshold, execute: timer)
    }

    private func cancelHold() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func reset() {
        cancelHold()
        keyIsDown = false
        usedAsCombo = false
        isHolding = false
        lastTap = nil
    }

    private func emit(_ event: HotkeyEvent) {
        DispatchQueue.main.async { self.onEvent(event) }
    }

    // MARK: - Key names

    /// Parses a dash-separated binding such as "cmd-shift-d".
    static func parse(_ binding: String) -> (keyCode: UInt16, modifiers: CGEventFlags)? {
        let parts = binding.lowercased().split(separator: "-").map(String.init)
        guard let key = parts.last, let keyCode = keyCodes[key] else { return nil }
        var modifiers: CGEventFlags = []
        for name in parts.dropLast() {
            guard let flag = modifierFlags[name] else { return nil }
            modifiers.insert(flag)
        }
        return (keyCode, modifiers)
    }

    private static let modifierFlags: [String: CGEventFlags] = {
        var flags: [String: CGEventFlags] = ["fn": .maskSecondaryFn, "function": .maskSecondaryFn]
        let names: [(CGEventFlags, [String])] = [
            (.maskCommand, ["command", "cmd"]),
            (.maskAlternate, ["option", "opt", "alt"]),
            (.maskControl, ["control", "ctrl"]),
            (.maskShift, ["shift"]),
        ]
        for (flag, aliases) in names {
            for alias in aliases {
                flags[alias] = flag
                flags["left" + alias] = flag
                flags["right" + alias] = flag
            }
        }
        return flags
    }()

    /// NX_DEVICE*KEYMASK values, which tell the left and right modifier keys apart.
    private static let deviceMasks: [String: UInt64] = [
        "leftcmd": 0x08, "leftcommand": 0x08, "rightcmd": 0x10, "rightcommand": 0x10,
        "leftshift": 0x02, "rightshift": 0x04,
        "leftctrl": 0x01, "leftcontrol": 0x01, "rightctrl": 0x2000, "rightcontrol": 0x2000,
        "leftoption": 0x20, "leftopt": 0x20, "leftalt": 0x20,
        "rightoption": 0x40, "rightopt": 0x40, "rightalt": 0x40,
    ]

    private static let keyCodes: [String: UInt16] = [
        "a": 0x00, "b": 0x0B, "c": 0x08, "d": 0x02, "e": 0x0E, "f": 0x03, "g": 0x05, "h": 0x04,
        "i": 0x22, "j": 0x26, "k": 0x28, "l": 0x25, "m": 0x2E, "n": 0x2D, "o": 0x1F, "p": 0x23,
        "q": 0x0C, "r": 0x0F, "s": 0x01, "t": 0x11, "u": 0x20, "v": 0x09, "w": 0x0D, "x": 0x07,
        "y": 0x10, "z": 0x06,
        "0": 0x1D, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "5": 0x17, "6": 0x16, "7": 0x1A,
        "8": 0x1C, "9": 0x19,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
        "escape": 0x35, "esc": 0x35, "space": 0x31, "tab": 0x30, "return": 0x24, "enter": 0x24,
        "delete": 0x33, "backspace": 0x33, "forwarddelete": 0x75,
    ]
}
