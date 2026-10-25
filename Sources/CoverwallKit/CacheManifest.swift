/// `profiles/<name>/manifest.json`: one entry per cached tile `tiles/<hash>.jpg`.
/// Keyed by the source's SHA-256 (dedupe); `mtime` lets `sync` skip unchanged files.
public struct CacheManifest: Codable, Equatable, Sendable {
    public var version = 1
    /// Size the tiles were encoded at; a different profile value re-encodes everything.
    public var tileMaxPixels: Int?
    public var tiles: [String: Tile] = [:]
    /// CLI-only, source path → tile hash for sources that matched an existing tile (tracks of one album), so a
    /// re-sync doesn't re-read them. Optional: manifests from before Phase 6 decode unchanged.
    public var duplicates: [String: Duplicate]?
    /// What the saver must obey (CLAUDE.md 9). Optional: caches from before Phase 7 are local-folder caches.
    public var policy: SourcePolicy?
    /// Seconds since 1970, like `mtime`. Past `expiresAt` the saver shows its fallback, never stale covers.
    public var syncedAt: Double?
    public var expiresAt: Double?

    public var sourcePolicy: SourcePolicy { policy ?? .localFolder }

    public struct Tile: Codable, Hashable, Sendable {
        public var source: String
        /// Seconds since 1970, as `stat` reports it.
        public var mtime: Double

        public init(source: String, mtime: Double) {
            self.source = source
            self.mtime = mtime
        }
    }

    public struct Duplicate: Codable, Hashable, Sendable {
        public var mtime: Double
        public var hash: String
    }

    public init() {}
}

/// How a source's covers may be cached and shown; written by the CLI, obeyed by the saver.
public struct SourcePolicy: Codable, Equatable, Sendable {
    public enum Crop: String, Codable, Sendable { case centerSquare, none }
    public enum Attribution: String, Codable, Sendable { case none, spotify }

    public var crop: Crop
    public var attribution: Attribution
    /// Seconds a cache may be shown after its sync; `nil` = forever.
    public var cacheTTL: Double?
    /// May share a grid with other sources' covers.
    public var mixable: Bool

    public init(crop: Crop, attribution: Attribution, cacheTTL: Double?, mixable: Bool) {
        (self.crop, self.attribution, self.cacheTTL, self.mixable) = (crop, attribution, cacheTTL, mixable)
    }

    public static let localFolder = SourcePolicy(crop: .centerSquare, attribution: .none, cacheTTL: nil, mixable: true)
}
