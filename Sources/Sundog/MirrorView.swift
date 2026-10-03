import AVFoundation
import AppKit

/// Shows the live iPhone screen, or a short instruction while no phone is mirroring.
@MainActor
final class MirrorView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)

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
        contextMenu.addItem(withTitle: "Quit Sundog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu = contextMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func attach(_ session: AVCaptureSession) {
        previewLayer.session = session
    }

    func show(_ state: PhoneCapture.State) {
        switch state {
        case .waitingForAccess:
            messageLabel.stringValue = "Starting…"
        case .accessDenied:
            messageLabel.stringValue = "Sundog needs camera access to show your iPhone.\n\nOpen System Settings > Privacy & Security > Camera, and turn on Sundog."
        case .waitingForPhone:
            messageLabel.stringValue = "Connect your iPhone with a USB cable.\n\nUnlock it, and tap Trust if it asks."
        case .mirroring:
            messageLabel.stringValue = ""
        }
        messageLabel.isHidden = state == .mirroring
        previewLayer.isHidden = state != .mirroring
    }
}
