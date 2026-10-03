import AVFoundation
import AppKit

/// Shows the iPhone screen. When no iPhone sends Screen Mirroring, it shows a short instruction.
@MainActor
final class MirrorView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    let videoSink: VideoSink
    var onHoverChange: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        videoSink = VideoSink(layer: displayLayer)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        displayLayer.videoGravity = .resizeAspect
        displayLayer.isHidden = true
        layer?.addSublayer(displayLayer)

        messageLabel.alignment = .center
        messageLabel.textColor = .white
        messageLabel.font = .systemFont(ofSize: 13)
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])

        let contextMenu = NSMenu()
        contextMenu.addItem(withTitle: "Stop Mirroring", action: #selector(AppDelegate.stopMirroring(_:)), keyEquivalent: "")
        contextMenu.addItem(withTitle: "Quit Sundog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChange?(false)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    func showMessage(_ text: String) {
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        displayLayer.isHidden = true
    }

    func showVideo() {
        messageLabel.isHidden = true
        displayLayer.isHidden = false
    }
}
