import Cocoa
import AVFoundation

enum SetupState {
    case requestingAccessibility
    case requestingMicrophone
    case downloadingModel
}

class SetupWindow {
    private var window: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var statusLabel: NSTextField?
    private var setupTask: Task<Void, Never>?

    var onSetupComplete: (() -> Void)?
    var onAccessibilityGranted: (() -> Void)?

    private static let baseDirectory: URL = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".texttap")
    }()

    static var needsSetup: Bool {
        let hasAccessibility = AXIsProcessTrusted()
        let hasMicrophone = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        let hasModel = modelExists()
        return !hasAccessibility || !hasMicrophone || !hasModel
    }

    private static func modelExists() -> Bool {
        let fm = FileManager.default

        // WhisperKit stores models in: ~/.texttap/models/argmaxinc/whisperkit-coreml/openai_whisper-*/
        let whisperKitPath = baseDirectory
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml")

        guard fm.fileExists(atPath: whisperKitPath.path),
              let contents = try? fm.contentsOfDirectory(atPath: whisperKitPath.path) else {
            return false
        }

        return contents.contains { $0.hasPrefix("openai_whisper-") }
    }

    func show() {
        if window != nil { return }

        let windowWidth: CGFloat = 280
        let windowHeight: CGFloat = 160
        let padding: CGFloat = 24

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.center()
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        window.contentView = contentView

        // Layout from bottom to top with equal padding
        let progressSize: CGFloat = 16
        let statusHeight: CGFloat = 14
        let titleHeight: CGFloat = 18
        let iconSize: CGFloat = 48
        let spacing: CGFloat = 8

        // Progress indicator at bottom
        let progressY = padding
        let progress = NSProgressIndicator(frame: NSRect(
            x: (windowWidth - progressSize) / 2,
            y: progressY,
            width: progressSize,
            height: progressSize
        ))
        progress.style = .spinning
        progress.controlSize = .small
        progress.startAnimation(nil)
        contentView.addSubview(progress)

        // Status label above progress
        let statusY = progressY + progressSize + spacing
        let status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.alignment = .center
        status.frame = NSRect(x: 20, y: statusY, width: windowWidth - 40, height: statusHeight)
        contentView.addSubview(status)
        self.statusLabel = status

        // Title label above status
        let titleY = statusY + statusHeight + spacing
        let titleLabel = NSTextField(labelWithString: "Setting up TextTap")
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.alignment = .center
        titleLabel.frame = NSRect(x: 20, y: titleY, width: windowWidth - 40, height: titleHeight)
        contentView.addSubview(titleLabel)

        // App icon at top with equal padding
        let iconY = windowHeight - iconSize - padding
        let iconView = NSImageView(frame: NSRect(
            x: (windowWidth - iconSize) / 2,
            y: iconY,
            width: iconSize,
            height: iconSize
        ))
        if let appIcon = NSApp.applicationIconImage {
            iconView.image = appIcon
        }
        iconView.imageScaling = .scaleProportionallyUpOrDown
        contentView.addSubview(iconView)

        self.window = window
        self.progressIndicator = progress

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        runSetupFlow()
    }

    private func runSetupFlow() {
        setupTask = Task { @MainActor [weak self] in
            guard let self = self, self.window != nil else { return }

            // Step 1: Request Accessibility permission
            if !AXIsProcessTrusted() {
                self.setState(.requestingAccessibility)
                self.promptForAccessibility()
                while !AXIsProcessTrusted() {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
                // Accessibility was just granted - notify so hotkey can be set up
                self.onAccessibilityGranted?()
            }

            guard self.window != nil else { return }

            // Step 2: Request Microphone permission
            let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            if micStatus != .authorized {
                self.setState(.requestingMicrophone)
                _ = await withCheckedContinuation { continuation in
                    AVCaptureDevice.requestAccess(for: .audio) { granted in
                        continuation.resume(returning: granted)
                    }
                }
            }

            guard self.window != nil else { return }

            // Step 3: Model download (handled by DictationManager)
            if !Self.modelExists() {
                self.setState(.downloadingModel)
            }

            self.onSetupComplete?()
        }
    }

    private func setState(_ state: SetupState) {
        switch state {
        case .requestingAccessibility:
            statusLabel?.stringValue = "Requesting accessibility access…"
        case .requestingMicrophone:
            statusLabel?.stringValue = "Requesting microphone access…"
        case .downloadingModel:
            statusLabel?.stringValue = "Downloading speech model…"
        }
    }

    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func hide() {
        setupTask?.cancel()
        setupTask = nil
        progressIndicator?.stopAnimation(nil)
        window?.close()
        window = nil
        progressIndicator = nil
        statusLabel = nil
    }
}
