import Cocoa
import ApplicationServices

class AppDelegate: NSObject, NSApplicationDelegate {
    // MARK: - Properties

    var statusItem: NSStatusItem!
    var statusBarMenu: StatusBarMenu!
    var dictationManager: DictationManager!
    var normalIcon: NSImage?
    var isModelLoading = true

    // Hotkey detection
    private var eventTap: CFMachPort?
    private var lastCmdUpTime: Date?
    private var cmdWasPressed = false

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMenu()
        setupDictationManager()
        setupGlobalHotkey()
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
            icon.size = NSSize(width: 14, height: 14)
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
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = true
            statusItem.button?.image = configuredIcon
            statusItem.button?.appearsDisabled = false
        }
    }

    func setIconActive() {
        if let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap Active") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .bold)
                .applying(.init(paletteColors: [.systemRed]))
            let configuredIcon = icon.withSymbolConfiguration(config) ?? icon
            configuredIcon.isTemplate = false
            statusItem.button?.image = configuredIcon
            statusItem.button?.appearsDisabled = false
        }
    }

    func setIconLoading() {
        if let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap Loading") {
            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
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
            print("[AppDelegate] Model still loading, ignoring dictation toggle")
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

    // MARK: - Global Hotkey (Double-tap Cmd + Esc)

    private func setupGlobalHotkey() {
        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

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
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Handle Esc key while dictation is active - CANCEL (no paste)
        if type == .keyDown && keyCode == 53 && dictationManager.isActive {
            DispatchQueue.main.async {
                print("[AppDelegate] Esc pressed - canceling dictation")
                self.dictationManager.stop()  // Cancel without pasting
            }
            return nil // Consume the event
        }

        // Handle Cmd key for double-tap detection
        if type == .flagsChanged {
            let cmdPressed = flags.contains(.maskCommand)

            // Detect Cmd key release (transition from pressed to not pressed)
            if cmdWasPressed && !cmdPressed {
                let now = Date()
                if let lastUp = lastCmdUpTime {
                    let interval = now.timeIntervalSince(lastUp)
                    if interval < Config.shared.hotkey.doubleTapInterval {
                        // Double-tap detected - toggle or paste
                        DispatchQueue.main.async {
                            if self.dictationManager.isActive {
                                print("[AppDelegate] Double-tap Cmd - stopping and pasting")
                                self.dictationManager.stopAndPaste()
                            } else {
                                self.toggleDictation()
                            }
                        }
                        lastCmdUpTime = nil
                    } else {
                        lastCmdUpTime = now
                    }
                } else {
                    lastCmdUpTime = now
                }
            }
            cmdWasPressed = cmdPressed
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

import AVFoundation
