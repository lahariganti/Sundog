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
    private let capture = PhoneCapture()
    private var panel: MirrorPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let panel = MirrorPanel()
        panel.mirrorView.attach(capture.session)
        capture.onStateChange = { [weak panel] state in
            panel?.mirrorView.show(state)
        }
        capture.onVideoSizeChange = { [weak panel] size in
            panel?.fit(videoSize: size)
        }
        panel.orderFrontRegardless()
        self.panel = panel

        capture.start()
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
