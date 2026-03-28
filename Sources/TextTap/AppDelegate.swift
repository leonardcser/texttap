import Cocoa
import ApplicationServices
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var statusBarMenu: StatusBarMenu!
    var dictationManager: DictationManager!
    var setupWindow: SetupWindow?

    // Hotkey detection
    private var eventTap: CFMachPort?
    private var lastTapTime: Date?
    private var keyDownTime: Date?
    private var holdTimer: DispatchSourceTimer?
    private var isHoldActive = false
    private var keyIsDown = false
    private var usedAsCombo = false

    private let holdThreshold: TimeInterval = 0.3

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        showSetupWindowIfNeeded()
        setupDictationManager()
        setupGlobalHotkey()
    }

    private func showSetupWindowIfNeeded() {
        if SetupWindow.needsSetup {
            setupWindow = SetupWindow()
            setupWindow?.onAccessibilityGranted = { [weak self] in
                self?.setupGlobalHotkey()
            }
            setupWindow?.onSetupComplete = { [weak self] in
                if self?.dictationManager?.isModelLoaded == true {
                    self?.setupWindow?.hide()
                    self?.setupWindow = nil
                }
            }
            setupWindow?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeGlobalHotkey()
        dictationManager?.cleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setIcon(for: .loading)
    }

    private func setupMenu() {
        statusBarMenu = StatusBarMenu()
        statusBarMenu.onToggleDictation = { [weak self] in
            self?.toggleDictation()
        }
        statusBarMenu.onReloadConfig = { Config.reload() }
        statusBarMenu.onQuit = { NSApplication.shared.terminate(nil) }
    }

    private func setupDictationManager() {
        dictationManager = DictationManager()
        dictationManager.onStateChange = { [weak self] state in
            DispatchQueue.main.async { self?.setIcon(for: state) }
        }
        dictationManager.onModelStateChange = { [weak self] isLoaded in
            DispatchQueue.main.async {
                if isLoaded {
                    let hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    if hasMicrophone {
                        self?.setupWindow?.hide()
                        self?.setupWindow = nil
                    }
                }
                self?.setIcon(for: isLoaded ? .idle : .loading)
            }
        }
    }

    // MARK: - Icon

    private enum IconState {
        case idle, recording, transcribing, loading
    }

    private func setIcon(for state: DictationState) {
        switch state {
        case .idle: setIcon(for: IconState.idle)
        case .recording: setIcon(for: IconState.recording)
        case .transcribing: setIcon(for: IconState.transcribing)
        }
    }

    private func setIcon(for state: IconState) {
        let symbolName = "circle.fill"
        guard let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: "TextTap") else { return }

        switch state {
        case .recording:
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            let img = icon.withSymbolConfiguration(config) ?? icon
            img.isTemplate = false
            statusItem.button?.image = img
            statusItem.button?.appearsDisabled = false

        case .idle:
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let img = icon.withSymbolConfiguration(config) ?? icon
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.appearsDisabled = false

        case .transcribing, .loading:
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let img = icon.withSymbolConfiguration(config) ?? icon
            img.isTemplate = true
            statusItem.button?.image = img
            statusItem.button?.appearsDisabled = true
        }
    }

    // MARK: - Status Item Click

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            statusBarMenu.show(from: statusItem, isActive: dictationManager.isActive, isLoading: !dictationManager.isModelLoaded)
        } else {
            toggleDictation()
        }
    }

    // MARK: - Dictation Toggle

    func toggleDictation() {
        guard dictationManager.isModelLoaded else { return }

        if !checkAccessibilityPermission() {
            showPermissionAlert(
                title: "Accessibility Permission Required",
                message: "TextTap needs Accessibility access for hotkey detection and cursor tracking.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            return
        }

        if !checkMicrophonePermission() {
            requestMicrophonePermission()
            return
        }

        if dictationManager.isActive {
            dictationManager.stopAndPaste()
        } else {
            dictationManager.start()
        }
    }

    // MARK: - Global Hotkey

    private func setupGlobalHotkey() {
        if eventTap != nil { return }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) |
                                     (1 << CGEventType.keyDown.rawValue) |
                                     (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return delegate.handleGlobalEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap - accessibility permission may be required")
            return
        }

        eventTap = tap
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func cancelHoldTimer() {
        holdTimer?.cancel()
        holdTimer = nil
    }

    private func removeGlobalHotkey() {
        cancelHoldTimer()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
    }

    private func handleGlobalEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Esc cancels active dictation
        if type == .keyDown && keyCode == 0x35 && dictationManager.dictationState != .idle {
            DispatchQueue.main.async { self.dictationManager.cancel() }
            return nil
        }

        let config = Config.shared.hotkey

        switch config.mode {
        case .doubleTap:
            return handleModifierKey(type: type, flags: flags, config: config, event: event)
        case .shortcut:
            return handleShortcutMode(type: type, keyCode: keyCode, flags: flags, config: config, event: event)
        }
    }

    /// Handles modifier key for both double-tap toggle and hold-to-talk.
    ///
    /// On key down: start a hold timer. If held past threshold → push-to-talk starts.
    /// On key up before threshold: treat as a tap → check for double-tap.
    /// On key up after hold: stop recording and transcribe.
    private func handleModifierKey(type: CGEventType, flags: CGEventFlags, config: HotkeyConfig, event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = config.key
        guard HotkeyConfig.isModifier(key) else {
            return Unmanaged.passUnretained(event)
        }
        guard let targetFlag = HotkeyConfig.modifierFlag(for: key) else {
            return Unmanaged.passUnretained(event)
        }
        // A non-modifier key pressed while our modifier is held → keyboard shortcut, not dictation
        if type == .keyDown && keyIsDown {
            usedAsCombo = true
            cancelHoldTimer()
            return Unmanaged.passUnretained(event)
        }

        guard type == .flagsChanged else {
            return Unmanaged.passUnretained(event)
        }

        let keyPressed: Bool
        if let deviceMask = HotkeyConfig.deviceModifierMask(for: key) {
            keyPressed = (flags.rawValue & deviceMask) != 0
        } else {
            keyPressed = flags.contains(targetFlag)
        }

        if keyPressed && !keyIsDown {
            let otherModifiers = flags.subtracting(targetFlag)
                .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
            keyIsDown = true
            usedAsCombo = !otherModifiers.isEmpty
            keyDownTime = Date()

            if !usedAsCombo {
                // If held past threshold → push-to-talk starts
                cancelHoldTimer()
                let timer = DispatchSource.makeTimerSource(queue: .main)
                timer.schedule(deadline: .now() + holdThreshold)
                timer.setEventHandler { [weak self] in
                    guard let self = self, self.keyIsDown, !self.usedAsCombo else { return }
                    self.isHoldActive = true
                    self.lastTapTime = nil
                    if self.dictationManager.dictationState == .idle {
                        self.toggleDictation()
                    }
                }
                timer.resume()
                holdTimer = timer
            }

        } else if keyPressed && keyIsDown && !usedAsCombo {
            // Another modifier added while our key is held → combo
            let otherModifiers = flags.subtracting(targetFlag)
                .intersection([.maskCommand, .maskAlternate, .maskShift, .maskControl])
            if !otherModifiers.isEmpty {
                usedAsCombo = true
                cancelHoldTimer()
            }

        } else if !keyPressed && keyIsDown {
            keyIsDown = false
            cancelHoldTimer()

            if usedAsCombo {
                return Unmanaged.passUnretained(event)
            }

            if isHoldActive {
                isHoldActive = false
                if dictationManager.isActive {
                    DispatchQueue.main.async { self.dictationManager.stopAndPaste() }
                }
            } else {
                let now = Date()
                if let lastTap = lastTapTime, now.timeIntervalSince(lastTap) < config.doubleTapInterval {
                    lastTapTime = nil
                    DispatchQueue.main.async { self.toggleDictation() }
                } else {
                    lastTapTime = now
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleShortcutMode(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                                    config: HotkeyConfig, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard let parsed = config.parsedShortcut,
              let targetKeyCode = HotkeyConfig.keyCode(for: parsed.key) else {
            return Unmanaged.passUnretained(event)
        }
        guard keyCode == targetKeyCode else { return Unmanaged.passUnretained(event) }

        var requiredFlags: CGEventFlags = []
        for modifier in parsed.modifiers {
            if let flag = HotkeyConfig.modifierFlag(for: modifier) {
                requiredFlags.insert(flag)
            }
        }

        if requiredFlags.isEmpty || flags.contains(requiredFlags) {
            DispatchQueue.main.async { self.toggleDictation() }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Permissions

    func checkAccessibilityPermission() -> Bool {
        AXIsProcessTrusted()
    }

    func checkMicrophonePermission() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.toggleDictation()
                } else {
                    self?.showPermissionAlert(
                        title: "Microphone Permission Required",
                        message: "TextTap needs microphone access to record speech.",
                        settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    )
                }
            }
        }
    }

    func showPermissionAlert(title: String, message: String, settingsURL: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: settingsURL) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
