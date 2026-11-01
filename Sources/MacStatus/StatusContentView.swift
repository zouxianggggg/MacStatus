import AppKit

// Stable geometry: throughput changes never change the menu item's width or anchor.
enum StatusLayout {
    static func width(for mode: MenuSpeedMode) -> CGFloat { mode == .hidden ? 24 : 88 }
    static func anchor(height: CGFloat) -> NSRect { NSRect(x: 4, y: 0, width: 20, height: height) }
}

final class StatusContentView: NSView {
    private var mode: MenuSpeedMode = .hidden
    private var download = "—"
    private var upload = "—"

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(mode: MenuSpeedMode, network: NetworkReading?) {
        let down = DisplayFormat.menuRate(network?.download)
        let up = DisplayFormat.menuRate(network?.upload)
        guard self.mode != mode || download != down || upload != up else { return }
        self.mode = mode
        download = down
        upload = up
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let color = (superview as? NSStatusBarButton)?.isHighlighted == true ? NSColor.selectedMenuItemTextColor : .labelColor
        StatusGlyph.draw(in: NSRect(x: 5, y: bounds.midY - 9, width: 18, height: 18), color: color)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: color, .paragraphStyle: paragraph
        ]
        func line(_ text: String, y: CGFloat) {
            (text as NSString).draw(in: NSRect(x: 28, y: y, width: 55, height: 11), withAttributes: attributes)
        }
        switch mode {
        case .hidden: break
        case .download: line("↓ " + download, y: bounds.midY - 5.5)
        case .upload: line("↑ " + upload, y: bounds.midY - 5.5)
        case .both:
            line("↓ " + download, y: bounds.midY)
            line("↑ " + upload, y: bounds.midY - 11)
        }
    }
}
