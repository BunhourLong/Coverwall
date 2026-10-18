/// `profiles/<name>/manifest.json`: one entry per cached tile `tiles/<hash>.jpg`.
/// Keyed by the source's SHA-256 (dedupe); `mtime` lets `sync` skip unchanged files.
public struct CacheManifest: Codable, Equatable, Sendable {
    public var version = 1
    public var tiles: [String: Tile] = [:]

    public struct Tile: Codable, Equatable, Sendable {
        public var source: String
        /// Seconds since 1970, as `stat` reports it.
        public var mtime: Double

        public init(source: String, mtime: Double) {
            self.source = source
            self.mtime = mtime
        }
    }

    public init() {}
}
