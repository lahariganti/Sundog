import AppKit
import Carbon.HIToolbox

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
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()

        let panel = MirrorPanel()
        panel.showMessage(Copy.starting)
        panel.orderFrontRegardless()
        self.panel = panel

        let receiver = AirPlayReceiver(name: "Sundog", sink: panel.mirrorView.videoSink) { [weak self, weak panel] event in
            // The main queue keeps the events in order. The window depends on that order.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
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
        }
        receiver.start()
        self.receiver = receiver

        // Control-Option-Command-S shows or hides the window from any app.
        hotKey = HotKey(keyCode: kVK_ANSI_S, modifiers: controlKey | optionKey | cmdKey) { [weak panel] in
            panel?.toggleVisibility()
        }
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(
            string: "Your iPhone, in a little window on your Mac.\n\nShow or hide the window from any app: Control-Option-Command-S.\n\n",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor]
        )
        credits.append(NSAttributedString(
            string: "Source code",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .link: URL(string: "https://github.com/lahariganti/Sundog")!]
        ))
        credits.append(NSAttributedString(
            string: " · AirPlay code from UxPlay",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: credits.length))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    @objc func showLicenses(_ sender: Any?) {
        LicensesWindow.show()
    }

    @objc func showWindow(_ sender: Any?) {
        panel?.orderFrontRegardless()
    }

    @objc func toggleWindow(_ sender: Any?) {
        panel?.toggleVisibility()
    }

    @objc func stopMirroring(_ sender: Any?) {
        receiver?.stopMirroring()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.action == #selector(stopMirroring(_:)) ? isMirroring : true
    }

    // The shortcut and the yellow button hide the window, and Sundog keeps running. The red button quits.
    /// A click on Sundog in the Dock shows the hidden window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panel?.orderFrontRegardless()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func makeMainMenu() -> NSMenu {
        let appMenu = NSMenu(title: "Sundog")
        appMenu.addItem(withTitle: "About Sundog", action: #selector(showAbout(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Licenses", action: #selector(showLicenses(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show Window", action: #selector(showWindow(_:)), keyEquivalent: "")
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
