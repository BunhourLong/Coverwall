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
        // `make host ARGS=--sheet`: the System Settings "Options…" sheet.
        if CommandLine.arguments.contains("--sheet"), let sheet = view.configureSheet { window.beginSheet(sheet) }
        // `make host ARGS="--snapshot out.png"`: the layer tree as a PNG after the covers load, then quit (no screen capture needed).
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                let scale = window.backingScaleFactor, size = view.bounds.size
                if let layer = view.layer, let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    context.scaleBy(x: scale, y: scale)
                    layer.render(in: context)
                    if let image = context.makeImage(),
                       let file = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) {
                        CGImageDestinationAddImage(file, image, nil)
                        CGImageDestinationFinalize(file)
                    }
                }
                NSApp.terminate(nil)
            }
        }

        let delegate = Delegate()
        app.delegate = delegate
        app.activate()
        withExtendedLifetime(delegate) { app.run() }
    }

    final class Delegate: NSObject, NSApplicationDelegate {
        func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    }
}
