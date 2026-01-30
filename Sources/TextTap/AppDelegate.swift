import Cocoa
import ApplicationServices
import AVFoundation

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    var statusItem: NSStatusItem!
    var statusBarMenu: StatusBarMenu!
    var dictationManager: DictationManager!
    var normalIcon: NSImage?
    var isModelLoading = true
    var setupWindow: SetupWindow?

    // Hotkey detection
    private var eventTap: CFMachPort?
    private var lastKeyUpTime: Date?
    private var keyWasPressed = false

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
                // Now that accessibility is granted, set up the global hotkey
                self?.setupGlobalHotkey()
            }
            setupWindow?.onSetupComplete = { [weak self] in
                // If model is already loaded, hide the window now
                // Otherwise, onModelStateChange will hide it when model loads
                if self?.isModelLoading == false {
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
        return false
    }

    // MARK: - Setup

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked(_:))
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Create a circle icon using SF Symbols
        if let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap") {
            icon.size = NSSize(width: 12, height: 12)
            normalIcon = icon
            setIconLoading()  // Start in loading state
        }
    }

    private func setupMenu() {
        statusBarMenu = StatusBarMenu()
        statusBarMenu.onToggleDictation = { [weak self] in
            self?.toggleDictation()
        }
        statusBarMenu.onReloadConfig = {
            Config.reload()
        }
        statusBarMenu.onQuit = {
            NSApplication.shared.terminate(nil)
        }
    }

    private func setupDictationManager() {
        dictationManager = DictationManager()
        dictationManager.onStateChange = { [weak self] isActive in
            DispatchQueue.main.async {
                if isActive {
                    self?.setIconActive()
                } else {
                    self?.setIconNormal()
                }
            }
        }
        dictationManager.onModelStateChange = { [weak self] isLoaded in
            DispatchQueue.main.async {
                self?.isModelLoading = !isLoaded
                if isLoaded {
                    // Only hide setup window if microphone permission is already granted
                    // Otherwise, let the setup flow complete and onSetupComplete will hide it
                    let hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                    if hasMicrophone {
                        self?.setupWindow?.hide()
                        self?.setupWindow = nil
                    }
                    self?.setIconNormal()
                } else {
                    self?.setIconLoading()
                }
            }
        }
    }

    // MARK: - Icon State

    func setIconNormal() {
        if let icon = normalIcon {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = true
            statusItem.button?.image = configuredIcon
            statusItem.button?.appearsDisabled = false
        }
    }

    func setIconActive() {
        if let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap Active") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = false
            statusItem.button?.image = configuredIcon
            statusItem.button?.appearsDisabled = false
        }
    }

    func setIconLoading() {
        if let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap Loading") {
            let config = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = true
            statusItem.button?.image = configuredIcon
            statusItem.button?.appearsDisabled = true  // Grays out the icon
        }
    }

    // MARK: - Status Item Click

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            statusBarMenu.show(from: statusItem, isActive: dictationManager.isActive, isLoading: isModelLoading)
        } else {
            toggleDictation()
        }
    }

    // MARK: - Dictation Toggle

    func toggleDictation() {
        // Check if model is still loading
        if isModelLoading {
            return
        }

        // Check permissions first
        if !checkAccessibilityPermission() {
            showPermissionAlert(
                title: "Accessibility Permission Required",
                message: "TextTap needs Accessibility access for hotkey detection and cursor tracking. Please grant permission in System Settings.",
                settingsAction: openAccessibilitySettings
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
        // Don't create a second tap if one already exists
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
                let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                return appDelegate.handleGlobalEvent(proxy: proxy, type: type, event: event)
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

    private func removeGlobalHotkey() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        eventTap = nil
    }

    private func handleGlobalEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let config = Config.shared.hotkey

        // Handle Esc key while dictation is active - CANCEL (no paste)
        if type == .keyDown && keyCode == 0x35 && dictationManager.isActive {
            DispatchQueue.main.async {
                self.dictationManager.stop()
            }
            return nil
        }

        switch config.mode {
        case .doubleTap:
            return handleDoubleTapMode(type: type, keyCode: keyCode, flags: flags, config: config, event: event)
        case .shortcut:
            return handleShortcutMode(type: type, keyCode: keyCode, flags: flags, config: config, event: event)
        }
    }

    private func handleDoubleTapMode(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                                     config: HotkeyConfig, event: CGEvent) -> Unmanaged<CGEvent>? {
        let key = config.key

        if HotkeyConfig.isModifier(key) {
            // Handle modifier key double-tap (e.g., Command, Option, Control, Shift)
            guard let targetFlag = HotkeyConfig.modifierFlag(for: key) else {
                return Unmanaged.passUnretained(event)
            }

            if type == .flagsChanged {
                let keyPressed: Bool
                if let deviceMask = HotkeyConfig.deviceModifierMask(for: key) {
                    // Side-specific modifier (e.g., leftcmd, rightcmd)
                    keyPressed = (flags.rawValue & deviceMask) != 0
                } else {
                    // Generic modifier (e.g., cmd, shift)
                    keyPressed = flags.contains(targetFlag)
                }

                // Detect key release (transition from pressed to not pressed)
                if keyWasPressed && !keyPressed {
                    handleDoubleTapRelease(config: config)
                }
                keyWasPressed = keyPressed
            }
        } else {
            // Handle regular key double-tap (e.g., F1, Escape, etc.)
            guard let targetKeyCode = HotkeyConfig.keyCode(for: key) else {
                return Unmanaged.passUnretained(event)
            }

            if keyCode == targetKeyCode {
                if type == .keyDown && !keyWasPressed {
                    keyWasPressed = true
                } else if type == .keyUp && keyWasPressed {
                    keyWasPressed = false
                    handleDoubleTapRelease(config: config)
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleDoubleTapRelease(config: HotkeyConfig) {
        let now = Date()
        if let lastUp = lastKeyUpTime {
            let interval = now.timeIntervalSince(lastUp)
            if interval < config.doubleTapInterval {
                // Double-tap detected - toggle or paste
                DispatchQueue.main.async {
                    if self.dictationManager.isActive {
                        self.dictationManager.stopAndPaste()
                    } else {
                        self.toggleDictation()
                    }
                }
                lastKeyUpTime = nil
            } else {
                lastKeyUpTime = now
            }
        } else {
            lastKeyUpTime = now
        }
    }

    private func handleShortcutMode(type: CGEventType, keyCode: UInt16, flags: CGEventFlags,
                                    config: HotkeyConfig, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        // Parse the shortcut string (e.g., "cmd-shift-d")
        guard let parsed = config.parsedShortcut,
              let targetKeyCode = HotkeyConfig.keyCode(for: parsed.key) else {
            return Unmanaged.passUnretained(event)
        }

        // Check if key matches
        guard keyCode == targetKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        // Check if all required modifiers are pressed
        var requiredFlags: CGEventFlags = []
        for modifier in parsed.modifiers {
            if let flag = HotkeyConfig.modifierFlag(for: modifier) {
                requiredFlags.insert(flag)
            }
        }

        // Verify all required modifiers are held
        let hasAllModifiers = requiredFlags.isEmpty || flags.contains(requiredFlags)

        if hasAllModifiers {
            DispatchQueue.main.async {
                if self.dictationManager.isActive {
                    self.dictationManager.stopAndPaste()
                } else {
                    self.toggleDictation()
                }
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Permission Checks

    func checkAccessibilityPermission() -> Bool {
        return AXIsProcessTrusted()
    }

    func checkMicrophonePermission() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        default:
            return false
        }
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.toggleDictation()
                } else {
                    self?.showPermissionAlert(
                        title: "Microphone Permission Required",
                        message: "TextTap needs microphone access to record speech for transcription. Please grant permission in System Settings.",
                        settingsAction: self?.openMicrophoneSettings ?? {}
                    )
                }
            }
        }
    }

    func showPermissionAlert(title: String, message: String, settingsAction: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            settingsAction()
        }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
