import AppKit

@main
@MainActor
enum SundogApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: MirrorPanel?
    private var receiver: AirPlayReceiver?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let panel = MirrorPanel()
        panel.mirrorView.showMessage(Copy.starting)
        panel.orderFrontRegardless()
        self.panel = panel

        let receiver = AirPlayReceiver(name: "Sundog", sink: panel.mirrorView.videoSink) { [weak panel] event in
            Task { @MainActor in
                guard let panel else { return }
                switch event {
                case .waiting:
                    panel.mirrorView.showMessage(Copy.waitingForMirroring)
                case .mirroring:
                    panel.mirrorView.showVideo()
                case .videoSize(let size):
                    panel.fit(videoSize: size)
                case .failed:
                    panel.mirrorView.showMessage(Copy.receiverFailed)
                }
            }
        }
        receiver.start()
        self.receiver = receiver
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Sundog")
        appMenu.addItem(withTitle: "About Sundog", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Sundog", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Sundog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(appItem)
        return mainMenu
    }
}

/// User-facing strings.
enum Copy {
    static let starting = "Starting…"
    static let waitingForMirroring = "On your iPhone, open Control Center and tap Screen Mirroring.\n\nThen select Sundog."
    static let receiverFailed = "Sundog cannot receive Screen Mirroring.\n\nMake sure that Wi-Fi is on. Then quit Sundog and open it again."
}
