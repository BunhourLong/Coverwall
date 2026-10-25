import Foundation

/// The only place that knows where shared data lives (SPIKE_NOTES.md Q2).
public enum Paths {
    static let container = "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

    /// Inside the sandbox `NSHomeDirectory()` already is the container; the CLI has to append it.
    public static var dataDir: URL {
        // Test-only: the end-to-end CLI tests point this at a temp dir.
        if let dir = ProcessInfo.processInfo.environment["COVERWALL_DATA_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.path.hasSuffix(container) ? home : home.appendingPathComponent(container)
        return base.appendingPathComponent("Library/Application Support/Coverwall", isDirectory: true)
    }

    /// CLI only: the CLI's own files (fallback secrets, sync log), outside the saver's container.
    public static var cliDir: URL {
        // Test-only, like COVERWALL_DATA_DIR.
        if let dir = ProcessInfo.processInfo.environment["COVERWALL_CLI_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/coverwall", isDirectory: true)
    }

    /// CLI only: held while a sync of `name` runs (outside the profile dir, which the sync swaps).
    public static func syncLock(_ name: String, in dir: URL = dataDir) -> URL { dir.appendingPathComponent("profiles/.\(name).lock") }

    /// CLI only: the scheduled sync's output.
    public static var syncLog: URL { cliDir.appendingPathComponent("sync.log") }

    /// CLI only: where `coverwall spotify schedule on` puts its LaunchAgent.
    public static var launchAgent: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/com.bunhourlong.Coverwall.sync.plist")
    }

    /// CLI only (in the sandbox the home dir is the container).
    public static var installedSaver: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Screen Savers/Coverwall.saver")
    }

    public static func config(in dir: URL = dataDir) -> URL { dir.appendingPathComponent("config.json") }
    public static func profile(_ name: String, in dir: URL = dataDir) -> URL { dir.appendingPathComponent("profiles/\(name)", isDirectory: true) }
    public static func manifest(_ name: String, in dir: URL = dataDir) -> URL { profile(name, in: dir).appendingPathComponent("manifest.json") }
    public static func tiles(_ name: String, in dir: URL = dataDir) -> URL { profile(name, in: dir).appendingPathComponent("tiles", isDirectory: true) }
    public static func tile(_ hash: String, of name: String, in dir: URL = dataDir) -> URL { tile(hash, inProfile: profile(name, in: dir)) }
    public static func tile(_ hash: String, inProfile profile: URL) -> URL { profile.appendingPathComponent("tiles/\(hash).jpg") }
    /// CLI only: where a sync builds the next cache of `name` before swapping it in (CLAUDE.md 10).
    public static func staging(_ name: String, in dir: URL = dataDir, id: String = UUID().uuidString) -> URL {
        dir.appendingPathComponent("profiles/.\(name).tmp-\(id)", isDirectory: true)
    }
}
