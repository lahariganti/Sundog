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
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var panel: MirrorPanel?
    private var receiver: AirPlayReceiver?
    private var isMirroring = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let panel = MirrorPanel()
        panel.showMessage(Copy.starting)
        panel.orderFrontRegardless()
        self.panel = panel

        let receiver = AirPlayReceiver(name: "Sundog", sink: panel.mirrorView.videoSink) { [weak self, weak panel] event in
            Task { @MainActor in
                guard let panel else { return }
                switch event {
                case .connecting:
                    panel.showMessage(Copy.connecting)
                case .waiting:
                    self?.isMirroring = false
                    panel.showMessage(Copy.waitingForMirroring)
                case .mirroring:
                    self?.isMirroring = true
                    panel.mirrorView.showVideo()
                case .videoSize(let size):
                    panel.fit(videoSize: size)
                case .failed:
                    self?.isMirroring = false
                    panel.showMessage(Copy.receiverFailed)
                }
            }
        }
        receiver.start()
        self.receiver = receiver
    }

    @objc func stopMirroring(_ sender: Any?) {
        receiver?.stopMirroring()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(stopMirroring(_:)) ? isMirroring : true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Sundog")
        appMenu.addItem(withTitle: "About Sundog", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Stop Mirroring", action: #selector(stopMirroring(_:)), keyEquivalent: ".")
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

/// The strings that the user sees in the window.
enum Copy {
    static let starting = "Starting…"
    static let waitingForMirroring = "On your iPhone, open Control Center.\nTap Screen Mirroring.\nSelect Sundog."
    static let connecting = "Connecting…"
    static let receiverFailed = "Sundog cannot receive Screen Mirroring.\n\nMake sure that Wi-Fi is on.\nQuit Sundog.\nOpen Sundog again."
}
