import AppKit

/// A small floating window. It remains above other apps, including full-screen slides.
/// Because it never takes focus, the slides or the code editor of the presenter remain active.
@MainActor
final class MirrorPanel: NSPanel {
    let mirrorView = MirrorView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        standardWindowButton(.zoomButton)?.isHidden = true
        showWindowButtons(false)
        mirrorView.onHoverChange = { [weak self] isInside in
            self?.showWindowButtons(isInside)
        }

        isFloatingPanel = true
        level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        backgroundColor = .black
        minSize = NSSize(width: 120, height: 120)

        contentView = mirrorView

        center()
        setFrameAutosaveName("SundogMirror")
    }

    /// Shows the close and minimize buttons only while the pointer is over the window.
    /// At all other times, the audience sees no buttons.
    private func showWindowButtons(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            standardWindowButton(button)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Changes the window shape to the shape of the iPhone screen. The window keeps its area and its center.
    /// Shows an instruction and resizes the window to the compact waiting size, around its center.
    func showMessage(_ text: String) {
        mirrorView.showMessage(text)
        let size = mirrorView.messageSize
        contentAspectRatio = size
        let current = frame
        let target = NSRect(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        setFrame(constrainFrameRect(target, to: screen), display: true, animate: isVisible)
    }

    func fit(videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let ratio = videoSize.width / videoSize.height
        contentAspectRatio = videoSize

        let current = frame
        let currentRatio = current.width / current.height
        guard abs(currentRatio - ratio) > 0.01 else { return }

        let area = current.width * current.height
        let height = (area / ratio).squareRoot()
        let width = height * ratio
        let fitted = NSRect(
            x: current.midX - width / 2,
            y: current.midY - height / 2,
            width: width,
            height: height
        )
        setFrame(fitted, display: true, animate: true)
    }
}
