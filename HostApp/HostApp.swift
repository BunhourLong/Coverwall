// Dev-only: the saver view in a normal resizable window, for fast iteration without installing.
// Reads the same data dir as the installed saver (Paths.dataDir). `make host`.

import AppKit

@main
@MainActor
enum HostApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        CoverwallView.alwaysInSession = true

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Coverwall HostApp"
        guard let view = CoverwallView(frame: window.contentLayoutRect, isPreview: false) else { return }
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.center()
        window.makeKeyAndOrderFront(nil)
        view.startAnimation()

        let delegate = Delegate()
        app.delegate = delegate
        app.activate()
        withExtendedLifetime(delegate) { app.run() }
    }

    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
