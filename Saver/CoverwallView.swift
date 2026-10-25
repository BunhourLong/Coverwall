// The saver: a dumb renderer of the CLI's cache (CLAUDE.md). Kit decides what and when; this file only
// feeds it lifecycle events and moves CALayers. All motion is Core Animation — no draw(_:), no per-frame code.

import AppKit
import ImageIO
import ScreenSaver
import os

private let log = Logger(subsystem: "com.bunhourlong.Coverwall", category: "saver")

@objc(CoverwallView)
final class CoverwallView: ScreenSaverView {
    /// HostApp: there is no screen saver session, so the view counts as always in one.
    static var alwaysInSession = false

    // Process-wide (one host process holds several instances, SPIKE_NOTES Q4 + Phase 3 probe).
    private static var created = 0
    private static var sessionActive = false
    private static var roster = SaverRoster()
    private static let instances = NSHashTable<CoverwallView>.weakObjects()
    private static let decodeQueue = DispatchQueue(label: "com.bunhourlong.Coverwall.decode", qos: .utility)

    private let id: Int
    private let compact: Bool
    private var activity: SaverActivity
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    // Only while active (CLAUDE.md constraint 5: idle = no timer, no decoded images).
    private var running = false
    private var generation = 0  // bumped on teardown; late decodes from an older run are dropped
    private var timer: Timer?
    private var bag: ShuffleBag?
    private var profile: Profile?
    private var expiresAt: Date?
    private var tileLayers: [CALayer] = []  // the image layers (each inside a perspective container)
    private var pixels: [Int] = []  // decode size per tile (heroes are bigger)
    private var decodedScale: CGFloat = 0
    private var busyUntil: [Int: CFTimeInterval] = [:]

    private static let flipDuration = 0.6, fadeDuration = 0.8, stagger = 0.15
    /// Height of the attribution band below the grid; never drawn over a cover (SPIKE_NOTES Phase 7.0).
    private var bandHeight: CGFloat { compact ? 12 : 40 }

    override init?(frame: NSRect, isPreview: Bool) {
        Self.created += 1
        id = Self.created
        // Preview-sized: the Settings thumbnail is small; on macOS 26 it's a 59×16 instance that never starts (SPIKE_NOTES).
        compact = isPreview || frame.width < 400 || frame.height < 300
        activity = SaverActivity(sessionActive: Self.sessionActive || compact || Self.alwaysInSession)
        super.init(frame: frame, isPreview: isPreview)
        Self.instances.add(self)
        animationTimeInterval = 3600  // swaps run on our own timer, never animateOneFrame

        let root = CALayer()
        root.backgroundColor = .black
        layer = root  // layer-hosting: assign the layer before wantsLayer
        wantsLayer = true

        activity.handle(.thermal(ProcessInfo.processInfo.thermalState))
        activity.handle(.lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled))
        activity.handle(.reduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion))
        observe()
        // Created mid-session = this session's own instance: load now instead of ~0.5 s later at
        // startAnimation, which showed as a black gap before the covers (Phase 3 round 3).
        if Self.sessionActive, !compact { handle(.animationStarted) }
        log.info("init #\(self.id) compact=\(self.compact) frame=\(NSStringFromRect(frame), privacy: .public)")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        observers.forEach { center, token in center.removeObserver(token) }
    }

    // MARK: - Lifecycle → SaverActivity

    private func observe() {
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        func on(_ center: NotificationCenter, _ name: Notification.Name, _ event: @escaping () -> SaverActivity.Event?) {
            observers.append((center, center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self, let event = event() else { return }
                self.handle(event)
            }))
        }
        let sessionEvents = !compact && !Self.alwaysInSession
        on(distributed, .init("com.apple.screensaver.didstart")) { sessionEvents ? .sessionStarted : nil }
        on(distributed, .init("com.apple.screensaver.willstop")) { sessionEvents ? .sessionStopped : nil }
        on(workspace, NSWorkspace.screensDidSleepNotification) { .displayAsleep(true) }
        on(workspace, NSWorkspace.screensDidWakeNotification) { .displayAsleep(false) }
        on(workspace, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification) {
            .reduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        }
        on(.default, ProcessInfo.thermalStateDidChangeNotification) { .thermal(ProcessInfo.processInfo.thermalState) }
        on(.default, .NSProcessInfoPowerStateDidChange) { .lowPower(ProcessInfo.processInfo.isLowPowerModeEnabled) }
    }

    override func startAnimation() {
        super.startAnimation()
        // A freshly launched host never gets didstart, but ScreenSaverEngine is already running then.
        if !compact, !Self.alwaysInSession,
           !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").isEmpty {
            handle(.sessionStarted)
        }
        // Only the newest instance on a screen is the one on display; the older one goes idle.
        let screen = (window?.screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        if let old = Self.roster.started(id, on: screen) {
            Self.instances.allObjects.first { $0.id == old }?.handle(.animationStopped)
        }
        handle(.animationStarted)
    }

    override func stopAnimation() {
        super.stopAnimation()
        handle(.animationStopped)
    }

    private func handle(_ event: SaverActivity.Event) {
        switch event {
        case .sessionStarted: Self.sessionActive = true
        case .sessionStopped: Self.sessionActive = false
        default: break
        }
        activity.handle(event)
        apply()
    }

    /// Brings the view in line with `activity`: start, stop, or retime.
    private func apply() {
        guard activity.isActive else { return teardown() }
        if !running { setUp() }
        guard let profile, bag != nil else { return }  // fallback message: nothing to animate
        let interval = activity.interval(base: profile.intervalSeconds)
        if timer?.timeInterval != interval { startTimer(interval) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size  // the host re-sets the same size right after init
        super.setFrameSize(newSize)
        if running, changed { teardown(); apply() }  // HostApp resizing: rebuild the grid for the new aspect ratio
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Set up at init (no window yet) used NSScreen.main's scale; rebuild at this screen's (multi-display).
        if running, window != nil, scale != decodedScale { teardown(); apply() }
    }

    // MARK: - Grid

    private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    private func setUp() {
        running = true
        // Re-read every time so `coverwall use` takes effect at the next start, no reload needed.
        switch SaverContent.load() {
        case .fallback(let message):
            log.notice("#\(self.id) fallback: \(message, privacy: .public)")
            showMessage(message)
        case .ready(_, let profile, let tiles, let policy, let expiresAt):
            self.profile = profile
            self.expiresAt = expiresAt
            let band = policy.attribution == .none ? 0 : bandHeight
            let seed = UInt64.random(in: .min ... .max)
            let grid = GridLayout(screen: CGSize(width: bounds.width, height: bounds.height - band), columns: profile.grid.columns, rows: profile.grid.rows, preview: compact,
                                  heroes: profile.heroes ?? 0, seed: seed)
            var bag = ShuffleBag(pool: tiles.map(\.path), slots: grid.slots, seed: seed)
            let first = bag.fill()
            self.bag = bag
            layer?.backgroundColor = Self.color(profile.background)
            tileLayers = (0..<first.count).map { index in
                let frame = grid.frame(ofTile: index).insetBy(dx: profile.gapPoints / 2, dy: profile.gapPoints / 2).offsetBy(dx: 0, dy: band)
                return makeTile(frame, span: grid.slots[index].span, gravity: policy.crop == .none ? .resizeAspect : .resizeAspectFill)
            }
            if policy.attribution == .spotify { showAttribution(height: band) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tileLayers.forEach { layer?.addSublayer($0.superlayer ?? $0) }
            CATransaction.commit()
            decodedScale = scale
            pixels = grid.slots.map { grid.pixelSize(scale: decodedScale, tileMax: profile.tileMaxPixels, span: $0.span) }
            decode(first, pixels: pixels) { [weak self] images in
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (index, image) in images.enumerated() { self.tileLayers[index].contents = image }
                CATransaction.commit()
            }
            log.notice("#\(self.id) active: \(grid.columns)x\(grid.rows), \(grid.slots.count) tiles, \(tiles.count) covers, \(self.pixels.min() ?? 0)–\(self.pixels.max() ?? 0) px @\(self.scale)x \(policy.crop.rawValue, privacy: .public)/\(policy.attribution.rawValue, privacy: .public) window=\(self.window != nil) size=\(NSStringFromSize(self.bounds.size), privacy: .public)")
        }
    }

    /// Releases everything: timer, decoded images, layers. Instances the host abandons stay like this.
    private func teardown() {
        guard running else { return }
        running = false
        generation += 1
        timer?.invalidate()
        timer = nil
        bag = nil
        profile = nil
        expiresAt = nil
        busyUntil = [:]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        tileLayers = []
        log.notice("#\(self.id) idle")
    }

    /// A container with per-tile perspective (so every flip looks the same) holding the image layer.
    private func makeTile(_ frame: CGRect, span: Int, gravity: CALayerContentsGravity) -> CALayer {
        let container = CALayer()
        container.frame = frame
        var perspective = CATransform3DIdentity
        perspective.m34 = -1 / (800 * CGFloat(span))  // camera distance scales with size: heroes flip like the rest
        container.sublayerTransform = perspective
        let image = CALayer()
        image.frame = container.bounds
        image.contentsGravity = gravity
        image.masksToBounds = true  // square covers in non-square tiles; a plain rect clip, no offscreen pass
        image.isOpaque = gravity == .resizeAspectFill  // aspect-fit leaves the background showing
        container.addSublayer(image)
        return image
    }

    private func startTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = interval / 10  // lets macOS coalesce wake-ups (§4.6)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        // Past the source's cache TTL: rebuild, which loads the fallback instead of stale covers.
        if let expiresAt, Date() >= expiresAt { teardown(); apply(); return }
        guard let profile, var bag else { return }
        let now = CACurrentMediaTime()
        let swaps = bag.tick(swaps: profile.swapsPerTick, busy: Set(busyUntil.filter { $0.value > now }.keys))
        self.bag = bag
        guard !swaps.isEmpty else { return }
        decode(swaps.map(\.image), pixels: swaps.map { pixels[$0.tile] }) { [weak self] images in
            guard let self else { return }
            let transition = self.activity.transition(preferred: profile.transition)
            let start = CACurrentMediaTime()
            for (i, (swap, image)) in zip(swaps, images).enumerated() {
                // ponytail: a cover that failed to decode keeps the old image on screen; the bag still counts it as shown.
                guard let image else { continue }
                self.animate(tile: swap.tile, to: image, transition, at: start + Double(i) * Self.stagger)
            }
        }
    }

    /// Swaps a tile's image entirely in the render server: no callbacks, no per-frame code.
    private func animate(tile index: Int, to image: CGImage, _ transition: Transition, at begin: CFTimeInterval) {
        let tile = tileLayers[index]
        let animation: CAAnimation
        switch transition {
        case .flip:
            // 0 → 90° ease-in, swap contents edge-on, −90° → 0 ease-out.
            let rotate = CAKeyframeAnimation(keyPath: "transform.rotation.y")
            rotate.values = [0, Double.pi / 2, -Double.pi / 2, 0]
            rotate.keyTimes = [0, 0.5, 0.5, 1]
            rotate.timingFunctions = [.init(name: .easeIn), .init(name: .linear), .init(name: .easeOut)]
            let swap = CAKeyframeAnimation(keyPath: "contents")
            swap.values = [tile.contents as Any, image]
            swap.keyTimes = [0, 0.5, 1]
            swap.calculationMode = .discrete
            let group = CAAnimationGroup()
            group.animations = [rotate, swap]
            group.duration = Self.flipDuration
            animation = group
        case .fade:
            let fade = CABasicAnimation(keyPath: "contents")
            fade.fromValue = tile.contents
            fade.toValue = image
            fade.duration = Self.fadeDuration
            animation = fade
        }
        animation.beginTime = begin
        animation.fillMode = .backwards  // keep the old image until this tile's staggered start
        busyUntil[index] = begin + animation.duration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tile.add(animation, forKey: "swap")
        tile.contents = image
        CATransaction.commit()
    }

    /// Decodes off main at tile pixel size; delivers on main only if this run is still current.
    private func decode(_ paths: [String], pixels: [Int], then deliver: @escaping ([CGImage?]) -> Void) {
        let generation = generation
        Self.decodeQueue.async { [weak self] in
            let images = zip(paths, pixels).map { Self.image(at: $0, pixels: $1) }
            DispatchQueue.main.async {
                guard let self, self.running, self.generation == generation else { return }
                deliver(images)
            }
        }
    }

    private nonisolated static func image(at path: String, pixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true,
                                        kCGImageSourceThumbnailMaxPixelSize: pixels]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - Configure sheet (read-only: the CLI is the control surface)

    override var hasConfigureSheet: Bool { true }

    override var configureSheet: NSWindow? {
        let text = NSTextField(wrappingLabelWithString: SaverContent.summary())
        text.isSelectable = true
        let close = NSButton(title: "Close", target: self, action: #selector(closeSheet))
        close.keyEquivalent = "\r"
        // Plain constraints, not NSStackView: its cross-axis insets are non-required and lose to the window size.
        let content = NSView()
        for view in [text, close] { view.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(view) }
        NSLayoutConstraint.activate([
            text.widthAnchor.constraint(equalToConstant: 420),
            text.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            text.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            text.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            close.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 12),
            close.trailingAnchor.constraint(equalTo: text.trailingAnchor),
            close.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.contentView = content
        return sheet
    }

    // sheetParent, not NSApp.endSheet: the latter is reported not to dismiss sheets in legacyScreenSaver.
    @objc private func closeSheet(_ sender: NSButton) {
        guard let sheet = sender.window else { return }
        if let parent = sheet.sheetParent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
    }

    // MARK: - Fallback

    private func showMessage(_ message: String) {
        let text = CATextLayer()
        text.string = message
        text.fontSize = compact ? 8 : 14
        text.alignmentMode = .center
        text.foregroundColor = CGColor(gray: 0.6, alpha: 1)
        text.contentsScale = scale
        text.frame = CGRect(x: 0, y: bounds.midY - text.fontSize, width: bounds.width, height: text.fontSize * 2)
        text.autoresizingMask = [.layerWidthSizable, .layerMinYMargin, .layerMaxYMargin]
        layer?.backgroundColor = .black
        layer?.addSublayer(text)
    }

    // shortcut: text placeholder; Phase 7.4 swaps in Spotify's official logo per the design guidelines.
    private func showAttribution(height: CGFloat) {
        let text = CATextLayer()
        text.string = "Spotify"
        text.fontSize = height * 0.4
        text.alignmentMode = .center
        text.foregroundColor = .white
        text.contentsScale = scale
        text.frame = CGRect(x: 0, y: (height - text.fontSize * 1.2) / 2, width: bounds.width, height: text.fontSize * 1.2)
        layer?.addSublayer(text)
    }

    /// `#RRGGBB`, already validated by `Config`; black if not.
    private static func color(_ hex: String) -> CGColor {
        guard let value = UInt32(hex.dropFirst(), radix: 16) else { return .black }
        return CGColor(red: CGFloat(value >> 16 & 0xFF) / 255, green: CGFloat(value >> 8 & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
