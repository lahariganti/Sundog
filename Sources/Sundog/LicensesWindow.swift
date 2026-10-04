import AppKit

/// Shows the license of Sundog and the notices of the third-party code. The GNU General Public
/// License asks an app with a user interface to make these notices available, for example from a menu.
@MainActor
enum LicensesWindow {
    private static let sourceCode = "https://github.com/lahariganti/Sundog"
    // The GPL asks for a copyright notice next to the license. The About panel does not show one.
    private static let copyright = "Copyright © 2026 Gantiplex"
    private static var window: NSWindow?

    static func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private static func makeWindow() -> NSWindow {
        let scrollView = NSTextView.scrollableTextView()
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.textContainerInset = NSSize(width: 16, height: 16)
            textView.textStorage?.setAttributedString(text())
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Licenses"
        window.contentView = scrollView
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }

    /// The copyright, the license summary, and the files that the build copies into the app.
    private static func text() -> NSAttributedString {
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor]
        let text = NSMutableAttributedString(
            string: "\(copyright)\n\nSundog is free software. You can share and change it under the terms of the GNU General Public License, version 3. It comes with no warranty. The full license is below.\n\nSource code: ",
            attributes: body
        )
        var link = body
        link[.link] = URL(string: sourceCode)
        text.append(NSAttributedString(string: sourceCode, attributes: link))
        for name in ["THIRD_PARTY_NOTICES.md", "LICENSE"] {
            guard let url = Bundle.main.url(forResource: name, withExtension: nil),
                  let file = try? String(contentsOf: url, encoding: .utf8) else { continue }
            text.append(NSAttributedString(string: "\n\n\n" + file, attributes: body))
        }
        return text
    }
}
