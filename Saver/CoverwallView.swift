// Phase 0 spike: show one image from the data dir, log everything the spike needs to answer.
// Throwaway — Phase 3 replaces this with the real grid renderer.

import AppKit
import ImageIO
import ScreenSaver
import os

private let log = Logger(subsystem: "com.bunhourlong.Coverwall", category: "spike")

// Spike-only: every event also goes to a file in the saver's own (writable) container, so the
// sandboxed run can be read back from Terminal without `log show`.
private let traceURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
    .first?.appendingPathComponent("coverwall-spike.log")

private func note(_ message: String) {
    log.notice("\(message, privacy: .public)")
    guard let traceURL else { return }
    let line = "\(Date().formatted(.iso8601.time(includingFractionalSeconds: true))) pid=\(getpid()) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: traceURL) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? Data(line.utf8).write(to: traceURL)
    }
}

@objc(CoverwallView)
final class CoverwallView: ScreenSaverView {
    private static var instanceCount = 0
    private static var liveCount = 0

    private let instance: Int
    private let treatAsPreview: Bool
    private var observers: [NSObjectProtocol] = []

    override init?(frame: NSRect, isPreview: Bool) {
        CoverwallView.instanceCount += 1
        CoverwallView.liveCount += 1
        instance = CoverwallView.instanceCount
        // Tahoe reports isPreview unreliably and spawns zero-frame ghost instances; the
        // System Settings thumbnail is small, so size is the safer signal.
        treatAsPreview = isPreview || frame.width < 400 || frame.height < 300
        super.init(frame: frame, isPreview: isPreview)

        let locked = (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
        note("init #\(instance) live=\(Self.liveCount) isPreview=\(isPreview) treatAsPreview=\(treatAsPreview) frame=\(NSStringFromRect(frame)) screenLocked=\(locked) home=\(NSHomeDirectory())")

        animationTimeInterval = 3600
        render()

        for name in ["willstart", "didstart", "willstop", "didstop"] {
            observers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.\(name)"), object: nil, queue: .main
            ) { [weak self] _ in self?.handle(name) })
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        observers.forEach(DistributedNotificationCenter.default().removeObserver)
        CoverwallView.liveCount -= 1
        note("deinit #\(instance) live=\(Self.liveCount)")
    }

    // No exit(0): on macOS 26.6 it kills the next session (see SPIKE_NOTES Q4). Tear down / resume instead.
    private func handle(_ name: String) {
        note("\(name) #\(instance) live=\(Self.liveCount) treatAsPreview=\(treatAsPreview)")
        switch name {
        case "willstop": layer?.sublayers?.forEach { $0.contents = nil }  // drop the decoded image
        case "didstart": render()
        default: break
        }
    }

    override func startAnimation() {
        super.startAnimation()
        note("startAnimation #\(instance)")
    }

    override func stopAnimation() {
        super.stopAnimation()
        note("stopAnimation #\(instance)")
    }

    // Candidate data dirs, in order. Inside the sandbox, Application Support resolves to the
    // legacyScreenSaver container; /Users/Shared is the fallback under test.
    private static var candidates: [(name: String, dir: URL)] {
        var dirs: [(String, URL)] = []
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            dirs.append(("container", support.appendingPathComponent("Coverwall")))
        }
        dirs.append(("shared", URL(fileURLWithPath: "/Users/Shared/Coverwall")))
        return dirs
    }

    private func render() {
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        layer = root  // layer-hosting: assign the layer before wantsLayer
        wantsLayer = true

        for (name, dir) in Self.candidates {
            do {
                let data = try Data(contentsOf: dir.appendingPathComponent("config.json"))
                guard let config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let file = config["image"] as? String else {
                    note("\(name): config.json has no \"image\" key")
                    continue
                }
                let url = dir.appendingPathComponent(file)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    note("\(name): cannot decode \(url.path)")
                    continue
                }
                note("#\(instance) \(name): OK read \(url.path)")
                let imageLayer = CALayer()
                imageLayer.frame = bounds
                imageLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
                imageLayer.contentsGravity = .resizeAspectFill
                imageLayer.contents = image
                root.addSublayer(imageLayer)
                addLabel("Coverwall spike · \(name) · pid \(getpid()) · instance #\(instance)", to: root)
                return
            } catch {
                note("#\(instance) \(name): \(error.localizedDescription)")
            }
        }
        addLabel("Coverwall: no image found — run spike/seed.sh", to: root)
    }

    private func addLabel(_ text: String, to root: CALayer) {
        let label = CATextLayer()
        label.string = text
        label.fontSize = treatAsPreview ? 8 : 16
        label.foregroundColor = NSColor(white: 0.8, alpha: 1).cgColor
        label.backgroundColor = NSColor(white: 0, alpha: 0.5).cgColor
        label.contentsScale = window?.backingScaleFactor ?? 2
        label.frame = CGRect(x: 0, y: 0, width: bounds.width, height: label.fontSize * 1.6)
        label.autoresizingMask = [.layerWidthSizable]
        root.addSublayer(label)
    }
}
