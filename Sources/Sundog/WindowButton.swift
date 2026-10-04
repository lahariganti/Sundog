import AppKit

/// A round window button in the style of the macOS close and minimize buttons.
/// The standard buttons stay disabled in a window that never becomes active, so Sundog draws its own.
@MainActor
final class WindowButton: NSButton {
    private let color: NSColor

    init(color: NSColor, toolTip: String, target: AnyObject?, action: Selector) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
        isBordered = false
        title = ""
        self.toolTip = toolTip
        self.target = target
        self.action = action
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 14, height: 14) }

    override func draw(_ dirtyRect: NSRect) {
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        circle.lineWidth = 1
        circle.stroke()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
