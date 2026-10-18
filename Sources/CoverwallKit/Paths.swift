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

    public static func config(in dir: URL = dataDir) -> URL { dir.appendingPathComponent("config.json") }
    public static func profile(_ name: String, in dir: URL = dataDir) -> URL { dir.appendingPathComponent("profiles/\(name)", isDirectory: true) }
    public static func manifest(_ name: String, in dir: URL = dataDir) -> URL { profile(name, in: dir).appendingPathComponent("manifest.json") }
    public static func tiles(_ name: String, in dir: URL = dataDir) -> URL { profile(name, in: dir).appendingPathComponent("tiles", isDirectory: true) }
    public static func tile(_ hash: String, of name: String, in dir: URL = dataDir) -> URL { tiles(name, in: dir).appendingPathComponent("\(hash).jpg") }
}
