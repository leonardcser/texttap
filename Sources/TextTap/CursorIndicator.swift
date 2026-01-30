import Cocoa

enum IndicatorState {
    case recording
    case loading
}

class CursorIndicator {
    private var panel: NSPanel?
    private var waveformView: WaveformView?

    private let config = Config.shared.indicator
    private var currentState: IndicatorState = .recording

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    var state: IndicatorState {
        currentState
    }

    func show() {
        guard config.enabled else { return }

        if panel == nil {
            createPanel()
        }

        panel?.orderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
        setState(.recording)
    }

    func updatePosition(_ rect: NSRect?) {
        guard let rect = rect, let panel = panel else { return }

        let x = rect.maxX + config.offsetX
        let y = rect.midY + config.offsetY - config.height / 2

        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    func updateLevel(_ level: Float) {
        waveformView?.updateLevel(level)
    }

    func reset() {
        waveformView?.reset()
    }

    func setState(_ state: IndicatorState) {
        currentState = state
        switch state {
        case .recording:
            waveformView?.setMode(.recording)
        case .loading:
            waveformView?.setMode(.loading)
        }
    }

    func cleanup() {
        panel?.close()
        panel = nil
        waveformView = nil
    }

    private func createPanel() {
        let frame = NSRect(x: 0, y: 0, width: config.width, height: config.height)

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        // Make sure it doesn't steal focus
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Create background view with pill shape
        let bgColor = config.bgColor.toNSColor()
        let backgroundView = NSView(frame: NSRect(x: 0, y: 0, width: config.width, height: config.height))
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = bgColor.cgColor
        backgroundView.layer?.cornerRadius = config.height / 2  // Fully rounded pill
        backgroundView.layer?.masksToBounds = true

        panel.contentView?.addSubview(backgroundView)

        // Create waveform view with padding
        let paddingX: CGFloat = 6
        let paddingY: CGFloat = 3
        let waveform = WaveformView(barCount: config.barCount)
        waveform.frame = NSRect(
            x: paddingX,
            y: paddingY,
            width: config.width - paddingX * 2,
            height: config.height - paddingY * 2
        )
        waveform.autoresizingMask = [.width, .height]
        waveform.accentColor = config.fgColor.toNSColor()

        backgroundView.addSubview(waveform)

        self.panel = panel
        self.waveformView = waveform
    }
}
