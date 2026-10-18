import Foundation

/// What the saver draws: the active profile's cached tiles, or a calm one-line fallback (PLAN.md §4.4).
/// Never throws — a broken data dir must not take down `legacyScreenSaver` (CLAUDE.md constraint 4).
public enum SaverContent: Equatable, Sendable {
    case ready(Profile, tiles: [URL])
    case fallback(String)

    private static let noProfile = SaverContent.fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\"")

    public static func load(from dir: URL = Paths.dataDir) -> SaverContent {
        guard let data = try? Data(contentsOf: Paths.config(in: dir)) else { return noProfile }
        guard let config = try? Config.decode(data) else {
            return .fallback("Coverwall: config.json is unreadable — run \"coverwall doctor\"")
        }
        guard let name = config.activeProfile, let profile = config.active else { return noProfile }
        let manifest = (try? Data(contentsOf: Paths.manifest(name, in: dir))).flatMap { try? JSONDecoder().decode(CacheManifest.self, from: $0) }
        // A tile that vanished (mid-sync, by hand) is skipped, never fatal.
        let tiles = (manifest?.tiles.keys.sorted() ?? []).map { Paths.tile($0, of: name, in: dir) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !tiles.isEmpty else { return .fallback("Coverwall: no covers for '\(name)' — run \"coverwall sync \(name)\"") }
        return .ready(profile, tiles: tiles)
    }
}
