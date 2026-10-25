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
