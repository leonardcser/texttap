import Cocoa

class StatusBarMenu: NSObject {
    var onToggleDictation: (() -> Void)?
    var onReloadConfig: (() -> Void)?
    var onQuit: (() -> Void)?

    private let menu: NSMenu

    override init() {
        menu = NSMenu()
        super.init()
    }

    // MARK: - Menu Construction

    private func buildMenu(isActive: Bool, isLoading: Bool) {
        menu.removeAllItems()

        // Version info
        if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            let versionItem = NSMenuItem(title: "TextTap v\(version)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)
            menu.addItem(NSMenuItem.separator())
        }

        if isLoading {
            // Show loading status
            let loadingItem = NSMenuItem(title: "Loading model...", action: nil, keyEquivalent: "")
            loadingItem.isEnabled = false
            menu.addItem(loadingItem)
        } else {
            // Toggle dictation
            let toggleTitle = isActive ? "Stop Dictation" : "Start Dictation"
            let toggleItem = NSMenuItem(title: toggleTitle, action: #selector(toggleClicked), keyEquivalent: "")
            toggleItem.target = self
            menu.addItem(toggleItem)

            // Hotkey hint
            let hotkeyItem = NSMenuItem(title: "Double-tap \u{2318} to toggle", action: nil, keyEquivalent: "")
            hotkeyItem.isEnabled = false
            menu.addItem(hotkeyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Reload Config
        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigClicked), keyEquivalent: "r")
        reloadItem.target = self
        menu.addItem(reloadItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    // MARK: - Menu Display

    func show(from statusItem: NSStatusItem, isActive: Bool, isLoading: Bool = false) {
        buildMenu(isActive: isActive, isLoading: isLoading)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Actions

    @objc private func toggleClicked() {
        onToggleDictation?()
    }

    @objc private func reloadConfigClicked() {
        onReloadConfig?()
    }

    @objc private func quitClicked() {
        onQuit?()
    }
}
