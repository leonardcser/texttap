import Cocoa

enum WaveformMode {
    case recording
    case loading
}

class WaveformView: NSView {
    private var levels: [CGFloat]
    private let barCount: Int
    private let barSpacing: CGFloat = 2
    private let minBarHeight: CGFloat = 2
    private let minLevel: CGFloat = 0.2

    var accentColor: NSColor = .white

    private var mode: WaveformMode = .recording

    init(barCount: Int = Config.shared.indicator.barCount) {
        self.barCount = barCount
        self.levels = Array(repeating: minLevel, count: barCount)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        self.barCount = Config.shared.indicator.barCount
        self.levels = Array(repeating: minLevel, count: barCount)
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = .clear
    }

    func updateLevel(_ rms: Float) {
        guard mode == .recording else { return }

        // Shift levels left, add new level on right
        levels.removeFirst()

        // Scale and clamp the level (RMS is typically 0.001-0.1 for speech)
        // Use logarithmic scaling for better visual response
        let normalized = max(0, min(1, (log10(max(rms, 0.0001)) + 4) / 3))  // Maps 0.0001-0.1 to 0-1
        let scaledLevel = max(minLevel, CGFloat(normalized))
        levels.append(scaledLevel)

        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: minLevel, count: barCount)
        needsDisplay = true
    }

    func setMode(_ newMode: WaveformMode) {
        guard mode != newMode else { return }
        mode = newMode

        // Animate opacity change
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            self.animator().alphaValue = newMode == .loading ? 0.4 : 1.0
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else { return }

        let availableWidth = bounds.width - CGFloat(barCount - 1) * barSpacing
        let barWidth = availableWidth / CGFloat(barCount)
        let maxBarHeight = bounds.height

        context.setFillColor(accentColor.cgColor)

        for (index, level) in levels.enumerated() {
            let barHeight = max(minBarHeight, level * maxBarHeight)
            let x = CGFloat(index) * (barWidth + barSpacing)
            let y = (bounds.height - barHeight) / 2

            // Fully rounded bars (pill shape)
            let cornerRadius = barWidth / 2
            let rect = CGRect(x: x, y: y, width: barWidth, height: barHeight)
            let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
            context.addPath(path)
            context.fillPath()
        }
    }
}
