import AppKit

/// A small floating window that stays above other apps, including full-screen slides.
/// It never takes focus, so the presenter's slides or editor stay active.
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

    /// Shows the close and minimize buttons only while the pointer is over the window,
    /// so the audience sees a clean window.
    private func showWindowButtons(_ visible: Bool) {
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton] {
            standardWindowButton(button)?.animator().alphaValue = visible ? 1 : 0
        }
    }

    /// Matches the window shape to the phone screen and keeps its area and center.
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
