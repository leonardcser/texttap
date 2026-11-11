import Cocoa

/// A floating pill next to the text caret with a live waveform and the preview text.
final class Overlay {
    private static let maxTextWidth: CGFloat = 360
    private static let textPadding: CGFloat = 8

    private let config: IndicatorConfig
    private let panel: NSPanel
    private let waveform: WaveformView
    private let label: NSTextField
    private let textColor: NSColor
    private var timer: Timer?

    init(config: IndicatorConfig) {
        self.config = config
        textColor = Self.color(config.fgColor)

        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: config.width, height: config.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let background = NSView(frame: panel.contentLayoutRect)
        background.autoresizingMask = [.width, .height]
        background.wantsLayer = true
        background.layer?.backgroundColor = Self.color(config.bgColor).cgColor
        background.layer?.cornerRadius = config.height / 2
        panel.contentView = background

        waveform = WaveformView(barCount: config.barCount)
        waveform.frame = NSRect(x: 6, y: 3, width: config.width - 12, height: config.height - 6)
        waveform.color = textColor
        background.addSubview(waveform)

        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: max(9, config.height - 7))
        label.maximumNumberOfLines = 1
        background.addSubview(label)
    }

    deinit {
        panel.close()
    }

    func show() {
        guard config.enabled else { return }
        waveform.reset()
        setBusy(false)
        setText("", pending: "")
        follow()
        panel.orderFront(nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.follow() }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    func setLevel(_ level: Float) {
        waveform.add(level)
    }

    /// Dims the waveform while the transcript is pending.
    func setBusy(_ busy: Bool) {
        waveform.alphaValue = busy ? 0.4 : 1
    }

    /// Shows `committed` text, followed by dimmed `pending` text that may still change.
    func setText(_ committed: String, pending: String) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingHead  // Keep the newest words visible
        let attributes: [NSAttributedString.Key: Any] = [.font: label.font!, .paragraphStyle: style, .foregroundColor: textColor]
        let text = NSMutableAttributedString(string: committed, attributes: attributes)
        if !pending.isEmpty {
            var dimmed = attributes
            dimmed[.foregroundColor] = textColor.withAlphaComponent(0.5)
            text.append(NSAttributedString(string: (committed.isEmpty ? "" : " ") + pending, attributes: dimmed))
        }
        label.attributedStringValue = text
        let isEmpty = text.length == 0
        let textWidth = isEmpty ? 0 : min(Self.maxTextWidth, ceil(label.fittingSize.width))
        let height = label.fittingSize.height
        label.frame = NSRect(x: config.width, y: (config.height - height) / 2, width: textWidth, height: height)
        var frame = panel.frame
        frame.size.width = config.width + (isEmpty ? 0 : textWidth + Self.textPadding)
        panel.setFrame(frame, display: true)
        follow()
    }

    /// Places the pill right of the caret, kept within the caret's screen.
    private func follow() {
        let caret = Caret.location()
        let size = panel.frame.size
        var origin = NSPoint(x: caret.maxX + config.offsetX, y: caret.midY + config.offsetY - size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - size.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - size.height))
        }
        panel.setFrameOrigin(origin)
    }

    private static func color(_ name: String) -> NSColor {
        let named: [String: NSColor] = [
            "white": .white, "black": .black, "red": .systemRed, "blue": .systemBlue,
            "green": .systemGreen, "orange": .systemOrange, "yellow": .systemYellow,
            "purple": .systemPurple, "pink": .systemPink, "gray": .systemGray,
            "cyan": .systemCyan, "teal": .systemTeal, "indigo": .systemIndigo,
        ]
        var key = name.lowercased()
        if key.hasPrefix("system") { key.removeFirst("system".count) }
        if let color = named[key] { return color }
        if name.hasPrefix("#"), let rgb = UInt64(name.dropFirst(), radix: 16) {
            return NSColor(
                red: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: 1
            )
        }
        return .systemBlue
    }
}

/// Bars showing the most recent audio levels.
final class WaveformView: NSView {
    private var levels: [CGFloat]
    private let minLevel: CGFloat = 0.2
    var color = NSColor.white

    init(barCount: Int) {
        levels = Array(repeating: minLevel, count: max(1, barCount))
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func add(_ level: Float) {
        // Speech RMS is roughly 0.0001 to 0.1, so map that range logarithmically to 0...1.
        let normalized = CGFloat(max(0, min(1, (log10(max(level, 0.0001)) + 4) / 3)))
        levels.removeFirst()
        levels.append(max(minLevel, normalized))
        needsDisplay = true
    }

    func reset() {
        levels = Array(repeating: minLevel, count: levels.count)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let spacing: CGFloat = 2
        let barWidth = (bounds.width - CGFloat(levels.count - 1) * spacing) / CGFloat(levels.count)
        context.setFillColor(color.cgColor)
        for (index, level) in levels.enumerated() {
            let height = max(2, level * bounds.height)
            let rect = CGRect(x: CGFloat(index) * (barWidth + spacing), y: (bounds.height - height) / 2, width: barWidth, height: height)
            context.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        }
        context.fillPath()
    }
}
