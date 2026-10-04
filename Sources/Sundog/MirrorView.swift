import AVFoundation
import AppKit

/// Shows the iPhone screen. When no iPhone sends Screen Mirroring, it shows a short instruction.
///
/// The official build adds a brand picture (`Brand.png` in the app resources). The view then shows
/// the picture above the instruction, on the picture's background color. Without the picture, the
/// instruction shows alone on black.
@MainActor
final class MirrorView: NSView {
    private static let brandBackground = NSColor(srgbRed: 0x1F / 255, green: 0x3F / 255, blue: 0xAE / 255, alpha: 1)

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let brandView = NSImageView()
    private let messageSpace = NSLayoutGuide()
    private let brandImage = Bundle.main.image(forResource: "Brand")
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
            messageLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
        ])

        if let brandImage {
            // The instruction is at the top. The picture fills the full width at the bottom, so that
            // the coat continues past the bottom edge of the window.
            brandView.image = brandImage
            brandView.imageScaling = .scaleProportionallyUpOrDown
            brandView.translatesAutoresizingMaskIntoConstraints = false
            addLayoutGuide(messageSpace)
            // The picture follows the window size. Without this, its pixel size forces the window to grow.
            for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
                brandView.setContentCompressionResistancePriority(.defaultLow, for: orientation)
                brandView.setContentHuggingPriority(.defaultLow, for: orientation)
            }
            addSubview(brandView)
            NSLayoutConstraint.activate([
                brandView.bottomAnchor.constraint(equalTo: bottomAnchor),
                brandView.leadingAnchor.constraint(equalTo: leadingAnchor),
                brandView.trailingAnchor.constraint(equalTo: trailingAnchor),
                brandView.heightAnchor.constraint(equalTo: brandView.widthAnchor),
                // Center the instruction in the space above the picture.
                messageSpace.topAnchor.constraint(equalTo: topAnchor, constant: 28),
                messageSpace.bottomAnchor.constraint(equalTo: brandView.topAnchor),
                messageLabel.centerYAnchor.constraint(equalTo: messageSpace.centerYAnchor),
            ])
        } else {
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }

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
        fade()
        messageLabel.stringValue = text
        messageLabel.isHidden = false
        brandView.isHidden = brandImage == nil
        displayLayer.isHidden = true
        layer?.backgroundColor = (brandImage == nil ? NSColor.black : Self.brandBackground).cgColor
    }

    func showVideo() {
        fade()
        messageLabel.isHidden = true
        brandView.isHidden = true
        displayLayer.isHidden = false
        layer?.backgroundColor = NSColor.black.cgColor
    }

    private func fade() {
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.25
        layer?.add(transition, forKey: "fade")
    }
}
