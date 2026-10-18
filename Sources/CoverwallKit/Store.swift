import Foundation

/// The CLI's view of the data dir: `config.json` + per-profile tile caches (PLAN.md §4.5).
public struct Store: Sendable {
    public let dataDir: URL

    public init(dataDir: URL = Paths.dataDir) {
        self.dataDir = dataDir
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
    public func add(_ name: String, _ profile: Profile) throws -> SyncReport {
        var config = try load()
        guard config.profiles[name] == nil else { throw StoreError.profileExists(name) }
        config.profiles[name] = profile
        config.activeProfile = config.activeProfile ?? name
        try config.validate()  // before sync: the name becomes a directory
        let report = try TileCache.sync(name, profile: profile, dataDir: dataDir)
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
    public func sync(_ name: String?) throws -> SyncReport {
        let (name, profile) = try resolve(name, in: load())
        return try TileCache.sync(name, profile: profile, dataDir: dataDir)
    }

    /// Applies `change` and saves; re-encodes the cache only if the tile size changed.
    public func update(_ name: String?, _ change: (inout Profile) -> Void) throws -> SyncReport? {
        var config = try load()
        let (name, before) = try resolve(name, in: config)
        var after = before
        change(&after)
        config.profiles[name] = after
        try save(config)
        return after.tileMaxPixels == before.tileMaxPixels ? nil : try TileCache.sync(name, profile: after, dataDir: dataDir)
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
        try? FileManager.default.removeItem(at: Paths.profile(name, in: dataDir))
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
