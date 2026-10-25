import Foundation

/// The CLI's view of the data dir: `config.json` + per-profile tile caches (PLAN.md §4.5).
public struct Store: Sendable {
    /// Turns a profile into its cover source; Kit only knows folders, the CLI adds Spotify (Kit has no networking).
    public typealias SourceFactory = @Sendable (Profile) throws -> any CoverSource

    public let dataDir: URL
    let now: @Sendable () -> Date
    let source: SourceFactory

    public init(dataDir: URL = Paths.dataDir, now: @escaping @Sendable () -> Date = Date.init,
                source: @escaping SourceFactory = { LocalFolderSource(folder: $0.source) }) {
        (self.dataDir, self.now, self.source) = (dataDir, now, source)
    }

    /// No config yet → empty config. Unreadable → error, so `save` never clobbers it.
    public func load() throws -> Config {
        let url = Paths.config(in: dataDir)
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        do { return try Config.decode(data) } catch is DecodingError { throw StoreError.corruptConfig(url.path) }
    }

    /// Validates before writing; atomic so the saver never sees half a file.
    public func save(_ config: Config) throws {
        try config.validate()
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(config).write(to: Paths.config(in: dataDir), options: .atomic)
    }

    /// Caches the tiles, saves the profile; the first profile becomes active.
    public func add(_ name: String, _ profile: Profile) async throws -> SyncReport {
        var config = try load()
        guard config.profiles[name] == nil else { throw StoreError.profileExists(name) }
        config.profiles[name] = profile
        config.activeProfile = config.activeProfile ?? name
        try config.validate()  // before sync: the name becomes a directory
        let report = try await cache(name, profile)
        try save(config)
        return report
    }

    /// `nil` → the active profile.
    public func resolve(_ name: String?, in config: Config) throws -> (name: String, profile: Profile) {
        guard let name = name ?? config.activeProfile else { throw StoreError.noActiveProfile }
        guard let profile = config.profiles[name] else { throw StoreError.unknownProfile(name) }
        return (name, profile)
    }

    /// Re-scans the source folder.
    public func sync(_ name: String?) async throws -> SyncReport {
        let (name, profile) = try resolve(name, in: load())
        return try await cache(name, profile)
    }

    private func cache(_ name: String, _ profile: Profile) async throws -> SyncReport {
        do {
            return try await TileCache.sync(name, from: source(profile), tileMaxPixels: profile.tileMaxPixels, dataDir: dataDir, now: now())
        } catch {
            // Past its expiry a cache goes even when the refresh fails: the source's terms win (PLAN.md §4.7).
            let manifest = try? JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: Paths.manifest(name, in: dataDir)))
            if let expiresAt = manifest?.expiresAt, now().timeIntervalSince1970 >= expiresAt { dropCache(name) }
            throw error
        }
    }

    /// Deletes the caches whose source limits how long covers may be kept (e.g. after a logout). Profiles stay.
    public func purgeExpiringCaches() throws -> [String] {
        try purgeCaches { $0.sourcePolicy.cacheTTL != nil }
    }

    /// Deletes caches past their `expiresAt` even if nobody syncs them (the saver already ignores them).
    public func purgeExpiredCaches() throws -> [String] {
        let now = now().timeIntervalSince1970
        return try purgeCaches { ($0.expiresAt ?? .infinity) <= now }
    }

    private func purgeCaches(where condemned: (CacheManifest) -> Bool) throws -> [String] {
        try load().profiles.keys.sorted().filter { name in
            let manifest = try? JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: Paths.manifest(name, in: dataDir)))
            guard let manifest, condemned(manifest) else { return false }
            dropCache(name)
            return true
        }
    }

    private func dropCache(_ name: String) {
        try? FileManager.default.removeItem(at: Paths.profile(name, in: dataDir))
        TileCache.removeStaging(name, in: dataDir)
    }

    /// Applies `change` and saves; re-encodes the cache only if the tile size changed.
    public func update(_ name: String?, _ change: (inout Profile) -> Void) async throws -> SyncReport? {
        var config = try load()
        let (name, before) = try resolve(name, in: config)
        var after = before
        change(&after)
        config.profiles[name] = after
        try save(config)
        return after.tileMaxPixels == before.tileMaxPixels ? nil : try await cache(name, after)
    }

    public func use(_ name: String) throws {
        var config = try load()
        config.activeProfile = try resolve(name, in: config).name
        try save(config)
    }

    /// Removing the active profile leaves none active (saver shows its fallback).
    public func remove(_ name: String) throws {
        var config = try load()
        guard config.profiles.removeValue(forKey: name) != nil else { throw StoreError.unknownProfile(name) }
        if config.activeProfile == name { config.activeProfile = nil }
        try save(config)
        dropCache(name)
    }
}

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case profileExists(String)
    case unknownProfile(String)
    case noActiveProfile
    case corruptConfig(String)

    public var description: String {
        switch self {
        case .profileExists(let name): "profile '\(name)' already exists — change it with `coverwall set \(name) ...` or `coverwall remove \(name)` first"
        case .unknownProfile(let name): "no profile named '\(name)' — run `coverwall list` to see profiles"
        case .noActiveProfile: "no active profile — name one, or pick one with `coverwall use <name>` (`coverwall list` shows them)"
        case .corruptConfig(let path): "\(path) is damaged or not a coverwall config — fix it by hand, or delete it and re-add your profiles"
        }
    }
}
