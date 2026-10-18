import Foundation

/// The only place that knows where shared data lives (SPIKE_NOTES.md Q2).
public enum Paths {
    static let container = "Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data"

    /// Inside the sandbox `NSHomeDirectory()` already is the container; the CLI has to append it.
    public static var dataDir: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let base = home.path.hasSuffix(container) ? home : home.appendingPathComponent(container)
        return base.appendingPathComponent("Library/Application Support/Coverwall", isDirectory: true)
    }

    public static var config: URL { dataDir.appendingPathComponent("config.json") }
    public static func profile(_ name: String) -> URL { dataDir.appendingPathComponent("profiles/\(name)", isDirectory: true) }
    public static func manifest(_ name: String) -> URL { profile(name).appendingPathComponent("manifest.json") }
    public static func tiles(_ name: String) -> URL { profile(name).appendingPathComponent("tiles", isDirectory: true) }
}
