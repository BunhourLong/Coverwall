import Foundation

/// `coverwall install` / `uninstall`: puts the built bundle into `~/Library/Screen Savers` (PLAN.md Phase 4).
public enum Installer {
    /// `make install` and the Homebrew formula both put the bundle in `<prefix>/share/coverwall`, next to `<prefix>/bin`.
    public static func bundledSaver(executable: URL) -> URL? {
        let saver = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../share/coverwall/Coverwall.saver").standardizedFileURL
        return FileManager.default.fileExists(atPath: saver.path) ? saver : nil
    }

    public static func install(_ saver: URL, to target: URL = Paths.installedSaver) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.copyItem(at: saver, to: target)
    }

    /// Returns false when nothing was installed.
    @discardableResult
    public static func uninstall(_ target: URL = Paths.installedSaver) throws -> Bool {
        guard FileManager.default.fileExists(atPath: target.path) else { return false }
        try FileManager.default.removeItem(at: target)
        return true
    }
}
