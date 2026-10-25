import Foundation

/// What the saver draws: the active profile's cached tiles, or a calm one-line fallback (PLAN.md §4.4).
/// Never throws — a broken data dir must not take down `legacyScreenSaver` (CLAUDE.md constraint 4).
public enum SaverContent: Equatable, Sendable {
    case ready(name: String, Profile, tiles: [URL], policy: SourcePolicy, expiresAt: Date?)
    case fallback(String)

    private static let noProfile = SaverContent.fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\"")

    public static func load(from dir: URL = Paths.dataDir, now: Date = Date()) -> SaverContent {
        guard let data = try? Data(contentsOf: Paths.config(in: dir)) else { return noProfile }
        guard let config = try? Config.decode(data) else {
            return .fallback("Coverwall: config.json is unreadable — run \"coverwall doctor\"")
        }
        guard let name = config.activeProfile, let profile = config.active else { return noProfile }
        let manifest = (try? Data(contentsOf: Paths.manifest(name, in: dir))).flatMap { try? JSONDecoder().decode(CacheManifest.self, from: $0) }
        // A tile that vanished (mid-sync, by hand) is skipped, never fatal.
        let tiles = (manifest?.tiles.keys.sorted() ?? []).map { Paths.tile($0, of: name, in: dir) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let manifest, !tiles.isEmpty else { return .fallback("Coverwall: no covers for '\(name)' — run \"coverwall sync \(name)\"") }
        let expiresAt = manifest.expiresAt.map { Date(timeIntervalSince1970: $0) }
        if let expiresAt, now >= expiresAt { return .fallback("Coverwall: covers for '\(name)' have expired — run \"coverwall sync \(name)\"") }
        return .ready(name: name, profile, tiles: tiles, policy: manifest.sourcePolicy, expiresAt: expiresAt)
    }

    /// The configure sheet's read-only text (PLAN.md Phase 6): the active profile, or the fallback message.
    public static func summary(from dir: URL = Paths.dataDir) -> String {
        switch load(from: dir) {
        case .fallback(let message): return message
        case .ready(let name, let profile, let tiles, _, _):
            let grid = profile.grid.rows.map { "\(profile.grid.columns)x\($0)" } ?? "\(profile.grid.columns) columns, rows fit the screen"
            let heroes = profile.heroes.map { $0 > 0 ? " · \($0) heroes" : "" } ?? ""
            return """
                Active profile: \(name)
                Folder: \(profile.source)
                Grid: \(grid)\(heroes) · every \(profile.intervalSeconds.formatted()) s · \(profile.transition.rawValue)
                \(tiles.count) covers
                Change it in Terminal: coverwall set, coverwall use <name>
                """
        }
    }
}
