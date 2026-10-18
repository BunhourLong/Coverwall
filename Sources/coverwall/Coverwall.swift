import AppKit
import ArgumentParser
import CoverwallKit

@main
struct Coverwall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "coverwall",
        abstract: "Control the Coverwall album-cover screen saver.",
        subcommands: [Add.self, Use.self, SetCommand.self, Sync.self, List.self, Remove.self,
                      Doctor.self, Reload.self, Preview.self, Settings.self])
}

// MARK: - Profiles

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add a profile: cache the covers in <folder> and remember its settings.")
    @Argument(help: "Profile name (letters, digits, '-', '_').") var name: String
    @Argument(help: "Folder of cover images (jpg, png, heic, webp, tiff).") var folder: String
    @OptionGroup var options: ProfileOptions
    @Flag(help: "Print the sync report as JSON.") var json = false

    func run() throws {
        var profile = Profile(source: URL(fileURLWithPath: (folder as NSString).expandingTildeInPath).standardizedFileURL.path)
        options.apply(to: &profile, fresh: true)
        try show(name, profile, Store().add(name, profile), json: json)
    }
}

struct Use: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Make a profile the one the screen saver shows.")
    @Argument var name: String

    func run() throws {
        try Store().use(name)
        print("\(name) is active — it shows the next time the screen saver starts (if not: `coverwall reload`)")
    }
}

struct SetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set", abstract: "Change a profile's grid, timing or transition.")
    @Argument(help: "Profile (default: the active one).") var name: String?
    @OptionGroup var options: ProfileOptions

    func validate() throws {
        guard options.changesSomething else {
            throw ValidationError("nothing to change — pass --grid, --columns, --interval, --transition or --tile-max")
        }
    }

    func run() throws {
        let store = Store()
        let report = try store.update(name) { options.apply(to: &$0, fresh: false) }
        let (name, profile) = try store.resolve(name, in: store.load())
        print("\(name): \(gridText(profile.grid)), every \(profile.intervalSeconds.formatted())s, \(profile.transition), tiles ≤ \(profile.tileMaxPixels) px")
        if let report { try show(name, profile, report, json: false) }
    }
}

struct Sync: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Re-scan a profile's folder (new, changed and deleted covers).")
    @Argument(help: "Profile (default: the active one).") var name: String?
    @Flag(help: "Print the sync report as JSON.") var json = false

    func run() throws {
        let store = Store()
        let (name, profile) = try store.resolve(name, in: store.load())
        try show(name, profile, store.sync(name), json: json)
    }
}

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List profiles; * marks the active one.")
    @Flag(help: "Print as JSON.") var json = false

    struct Entry: Encodable {
        let name: String, active: Bool, images: Int, profile: Profile
    }

    func run() throws {
        let config = try Store().load()
        let entries = config.profiles.sorted { $0.key < $1.key }
            .map { Entry(name: $0.key, active: $0.key == config.activeProfile, images: tileCount($0.key), profile: $0.value) }
        if json { return try printJSON(entries) }
        if entries.isEmpty { return print("no profiles — add one with `coverwall add <name> <folder>`") }
        for e in entries {
            print("\(e.active ? "*" : " ") \(e.name)  \(gridText(e.profile.grid))  \(e.images) images  \(e.profile.source)")
        }
    }
}

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a profile and its cached tiles (your folder is untouched).")
    @Argument var name: String

    func run() throws {
        let store = Store()
        let wasActive = try store.load().activeProfile == name
        try store.remove(name)
        print("removed \(name)" + (wasActive ? " — no active profile now, pick one with `coverwall use <name>`" : ""))
    }
}

struct ProfileOptions: ParsableArguments {
    @Option(help: "Columns x rows, e.g. 7x5 (default for new profiles).") var grid: Grid?
    @Option(help: "Columns only; rows fit each screen.") var columns: Int?
    @Option(help: "Seconds between swaps.") var interval: Double?
    @Option(help: "flip or fade.") var transition: Transition?
    @Option(name: .customLong("tile-max"), help: "Cached tile size in pixels (default: sharp on your best display).") var tileMax: Int?

    func validate() throws {
        if grid != nil && columns != nil { throw ValidationError("use --grid or --columns, not both") }
    }

    var changesSomething: Bool { grid != nil || columns != nil || interval != nil || transition != nil || tileMax != nil }

    /// New profiles and grid changes get a tile size computed from the displays unless --tile-max is given.
    func apply(to profile: inout Profile, fresh: Bool) {
        let newGrid = grid ?? columns.map { Grid(columns: $0, rows: nil) }
        if let newGrid { profile.grid = newGrid }
        if let interval { profile.intervalSeconds = interval }
        if let transition { profile.transition = transition }
        if let tileMax {
            profile.tileMaxPixels = tileMax
        } else if fresh || newGrid != nil {
            let displays = MainActor.assumeIsolated { NSScreen.screens.map { (points: $0.frame.size, scale: $0.backingScaleFactor) } }
            profile.tileMaxPixels = GridLayout.defaultTileMax(columns: profile.grid.columns, rows: profile.grid.rows, displays: displays)
        }
    }
}

extension Grid: ExpressibleByArgument {
    public init?(argument: String) { self.init(parsing: argument) }
}

extension Transition: ExpressibleByArgument {}

// MARK: - System

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check the install, data dir, config and caches.")
    @Flag(help: "Print as JSON.") var json = false

    struct Check: Encodable {
        let name: String, ok: Bool, detail: String
    }

    func run() throws {
        var checks: [Check] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { checks.append(Check(name: name, ok: ok, detail: detail)) }
        let fm = FileManager.default

        let os = ProcessInfo.processInfo.operatingSystemVersion
        check("macOS", ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 6, patchVersion: 0)),
              "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) (needs 14.6 or later)")
        let saver = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/Coverwall.saver")
        let installed = fm.fileExists(atPath: saver.path)
        check("saver installed", installed, installed ? saver.path : "not in ~/Library/Screen Savers — run `make install`")
        let dir = Paths.dataDir
        let writable = (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil && fm.isWritableFile(atPath: dir.path)
        check("data dir writable", writable, dir.path)
        do {
            let config = try Store().load()
            check("config", config.active != nil,
                  config.activeProfile.map { "active profile: \($0)" } ?? "no active profile — run `coverwall add <name> <folder>` or `coverwall use <name>`")
            for (name, profile) in config.profiles.sorted(by: { $0.key < $1.key }) {
                var isFolder: ObjCBool = false
                let source = fm.fileExists(atPath: profile.source, isDirectory: &isFolder) && isFolder.boolValue
                let tiles = tileCount(name)
                check("profile \(name)", source && tiles > 0,
                      "\(tiles) tiles" + (source ? "" : ", folder missing: \(profile.source)") + (tiles > 0 ? "" : " — run `coverwall sync \(name)`"))
            }
        } catch {
            check("config", false, "\(error)")
        }
        let hosts = try shell("/usr/bin/pgrep", "-x", "legacyScreenSaver").output.split(separator: "\n").count
        check("legacyScreenSaver processes", hosts <= 1, "\(hosts) running" + (hosts > 1 ? " — run `coverwall reload`" : ""))

        if json {
            try printJSON(checks)
        } else {
            for c in checks { print("\(c.ok ? "✓" : "✗") \(c.name): \(c.detail)") }
        }
        if checks.contains(where: { !$0.ok }) { throw ExitCode.failure }
    }
}

struct Reload: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Quit the screen saver host so macOS loads the newest bundle next time.")

    func run() throws {
        let killed = try shell("/usr/bin/killall", "legacyScreenSaver").status == 0
        print(killed ? "reloaded — macOS restarts the screen saver host when it's next needed" : "legacyScreenSaver wasn't running — nothing to reload")
    }
}

struct Preview: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Start the screen saver now.")

    func run() throws {
        guard try shell("/usr/bin/open", "-a", "ScreenSaverEngine").status == 0 else {
            throw ValidationError("couldn't start ScreenSaverEngine — try System Settings → Screen Saver → Preview")
        }
    }
}

struct Settings: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Open the screen saver settings (Wallpaper on macOS 26+, Screen Saver before).")

    func run() throws {
        // macOS 26 folded the Screen Saver pane into Wallpaper; the old id opens General there.
        let tahoe = ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        let pane = tahoe ? "com.apple.Wallpaper-Settings.extension" : "com.apple.ScreenSaver-Settings.extension"
        guard try shell("/usr/bin/open", "x-apple.systempreferences:\(pane)").status == 0 else {
            throw ValidationError("couldn't open System Settings — open it by hand: \(tahoe ? "Wallpaper → Screen Saver" : "Screen Saver"), then pick Coverwall")
        }
    }
}

// MARK: - Helpers

/// `add`/`sync` output, e.g. `mac: 100 images (3 skipped, 2 duplicates) → 7x5 grid, 35 visible`.
func show(_ name: String, _ profile: Profile, _ report: SyncReport, json: Bool) throws {
    if json { return try printJSON(report) }
    let notes = [report.skipped.isEmpty ? nil : "\(report.skipped.count) skipped",
                 report.duplicates == 0 ? nil : "\(report.duplicates) duplicates"].compactMap { $0 }
    let visible = profile.grid.rows.map { "\(gridText(profile.grid)) grid, \(profile.grid.columns * $0) visible" }
        ?? "\(gridText(profile.grid)), rows fit each screen"
    print("\(name): \(report.images) images" + (notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))") + " → \(visible)")
    for path in report.skipped { warn("  skipped (unreadable or not an image): \(path)") }
    if report.images == 0 { warn("  no covers found — supported: jpg, jpeg, png, heic, webp, tiff") }
}

func gridText(_ grid: Grid) -> String { grid.rows.map { "\(grid.columns)x\($0)" } ?? "\(grid.columns) columns" }

func tileCount(_ name: String) -> Int { (try? FileManager.default.contentsOfDirectory(atPath: Paths.tiles(name).path).count) ?? 0 }

func printJSON(_ value: some Encodable) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func warn(_ line: String) { FileHandle.standardError.write(Data((line + "\n").utf8)) }

/// Runs a system tool; output is stdout only.
func shell(_ tool: String, _ arguments: String...) throws -> (status: Int32, output: String) {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return (process.terminationStatus, output)
}
