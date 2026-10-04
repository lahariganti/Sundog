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
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
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

        contentView = mirrorView

        center()
        setFrameAutosaveName("SundogMirror")

        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSnap() }
        }
    }

    // MARK: Snap to corners

    private static let snapDistance: CGFloat = 60
    private static let cornerMargin: CGFloat = 16
    private var snapTimer: Timer?

    /// Waits until the drag ends, then snaps the window into a screen corner when it is near one.
    private func scheduleSnap() {
        snapTimer?.invalidate()
        snapTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if NSEvent.pressedMouseButtons & 1 != 0 {
                    self.scheduleSnap()
                } else {
                    self.snapToCorner()
                }
            }
        }
    }

    private func snapToCorner() {
        guard let area = screen?.visibleFrame else { return }
        let current = frame
        let nearLeft = current.minX - area.minX < Self.snapDistance
        let nearRight = area.maxX - current.maxX < Self.snapDistance
        let nearBottom = current.minY - area.minY < Self.snapDistance
        let nearTop = area.maxY - current.maxY < Self.snapDistance
        guard (nearLeft || nearRight) && (nearBottom || nearTop) else { return }
        let x = nearLeft ? area.minX + Self.cornerMargin : area.maxX - Self.cornerMargin - current.width
        let y = nearBottom ? area.minY + Self.cornerMargin : area.maxY - Self.cornerMargin - current.height
        let target = NSRect(x: x, y: y, width: current.width, height: current.height)
        guard target.origin != current.origin else { return }
        setFrame(target, display: true, animate: true)
    }

    /// Shows the window, or hides it. Mirroring continues while the window is hidden.
    func toggleVisibility() {
        if isVisible {
            orderOut(nil)
        } else {
            orderFrontRegardless()
        }
    }

    /// Shows the close and minimize buttons only while the pointer is over the window.
    /// At all other times, the audience sees no buttons.
    private func showWindowButtons(_ visible: Bool) {
        mirrorView.showWindowButtons(visible)
    }

    /// The waiting screen has the shape of a standard 6.1-inch iPhone in portrait (1179 x 2556 pixels).
    private static let waitingSize = CGSize(width: 300, height: 650)

    /// Shows an instruction and resizes the window to the waiting size, around its center.
    func showMessage(_ text: String) {
        mirrorView.showMessage(text)
        let size = Self.waitingSize
        contentAspectRatio = size
        // The instruction must fit in three lines.
        contentMinSize = NSSize(width: 240, height: 520)
        let current = frame
        let target = NSRect(
            x: current.midX - size.width / 2,
            y: current.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        setFrame(constrainFrameRect(target, to: screen), display: true, animate: isVisible)
        invalidateShadow()
    }

    /// A short resize animation, so that a rotation of the iPhone feels immediate.
    override func animationResizeTime(_ newFrame: NSRect) -> TimeInterval {
        0.15
    }

    /// Changes the window shape to the shape of the iPhone screen. The window keeps its area and its center.
    func fit(videoSize: CGSize) {
        guard videoSize.width > 0, videoSize.height > 0 else { return }
        let ratio = videoSize.width / videoSize.height
        contentAspectRatio = videoSize
        // The short side stays at least 160 points, so that the iPhone screen stays readable.
        let shortSide: CGFloat = 160
        contentMinSize = ratio < 1
            ? NSSize(width: shortSide, height: shortSide / ratio)
            : NSSize(width: shortSide * ratio, height: shortSide)

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
        invalidateShadow()
    }
}
