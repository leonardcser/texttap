import Cocoa
import AVFoundation

/// Connects the hotkey and the menu bar item to dictation, and asks for permissions.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    // Changing the local model takes effect after a restart.
    private let whisper = Whisper(model: Config.shared.transcription.model)
    private let vad = SileroVAD()
    private var dictation: Dictation!
    private var hotkey: Hotkey!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = Config.shared
        Task { await whisper.preload() }
        Task { await vad.preload() }
        dictation = makeDictation(config)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        showState(.idle)

        hotkey = Hotkey(config: config.hotkey)
        hotkey.onEvent = { [weak self] in self?.handle($0) }
        hotkey.capturesEscape = { [weak self] in self?.dictation.state != .idle }
        hotkey.isPaused = { [weak self] in self?.dictation.state == .transcribing }

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        installHotkeyWhenTrusted()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey.uninstall()
        dictation.cancel()
    }

    private func makeDictation(_ config: Config) -> Dictation {
        let dictation = Dictation(config: config, whisper: whisper, vad: vad)
        dictation.onStateChange = { [weak self] in self?.showState($0) }
        return dictation
    }

    private func handle(_ event: HotkeyEvent) {
        switch event {
        case .toggle:
            toggle()
        case .holdBegan:
            if dictation.state == .idle { toggle() }
        case .holdEnded:
            if dictation.state == .recording { dictation.stop() }
        case .holdCancelled:
            if dictation.state == .recording { dictation.cancel() }
        case .escape:
            dictation.cancel()
        }
    }

    private func toggle() {
        guard dictation.state == .idle else { return dictation.toggle() }
        guard AXIsProcessTrusted() else {
            return showPermissionAlert(
                "Accessibility Permission Required",
                "TextTap needs Accessibility access to detect the hotkey, find the cursor and insert text.",
                pane: "Privacy_Accessibility"
            )
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            dictation.start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { if granted { self.dictation.start() } }
            }
        default:
            showPermissionAlert(
                "Microphone Permission Required",
                "TextTap needs microphone access to record speech.",
                pane: "Privacy_Microphone"
            )
        }
    }

    /// Asks for Accessibility once and installs the hotkey as soon as it is granted.
    private func installHotkeyWhenTrusted() {
        let prompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        guard AXIsProcessTrustedWithOptions([prompt: true] as CFDictionary) else {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
                guard AXIsProcessTrusted() else { return }
                timer.invalidate()
                self?.hotkey.install()
            }
            return
        }
        if !hotkey.install() {
            print("[TextTap] Could not install the hotkey event tap")
        }
    }

    private func reloadConfig() {
        Config.reload()
        hotkey.config = Config.shared.hotkey
        if dictation.state == .idle {
            dictation = makeDictation(Config.shared)
        }
    }

    // MARK: - Menu bar

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            toggle()
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
        menu.addItem(withTitle: "TextTap \(version)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        menu.addItem(item(dictation.state == .idle ? "Start Dictation" : "Stop Dictation") { $0.toggle() })
        menu.addItem(item("Reload Config") { $0.reloadConfig() })
        menu.addItem(.separator())
        menu.addItem(item("Quit TextTap") { _ in NSApp.terminate(nil) })
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func item(_ title: String, action: @escaping (AppDelegate) -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
        let target = MenuAction { [weak self] in if let self { action(self) } }
        item.target = target
        item.representedObject = target  // Menu items hold their target weakly
        return item
    }

    private func showState(_ state: DictationState) {
        guard let icon = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "TextTap") else { return }
        var symbol = NSImage.SymbolConfiguration(pointSize: 12, weight: state == .recording ? .bold : .regular)
        if state == .recording {
            symbol = symbol.applying(.init(paletteColors: [.systemRed]))
        }
        let image = icon.withSymbolConfiguration(symbol) ?? icon
        image.isTemplate = state != .recording
        statusItem.button?.image = image
        statusItem.button?.appearsDisabled = state == .transcribing
    }

    private func showPermissionAlert(_ title: String, _ message: String, pane: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private final class MenuAction: NSObject {
    private let action: () -> Void

    init(_ action: @escaping () -> Void) {
        self.action = action
    }

    @objc func run() {
        action()
    }
}
