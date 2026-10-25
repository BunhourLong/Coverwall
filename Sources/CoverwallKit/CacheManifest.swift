import CoreGraphics

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

// Spotify's design guidelines (SPIKE_NOTES Phase 7.0): full logo ≥ 70 pt wide, clear space of ½ the icon height on every
// side, never drawn over a cover, covers with rounded corners (8 pt on large screens). The bundled full logo has no
// padding and its icon is as tall as the logo, so the clear space is half the logo height.
extension SourcePolicy.Attribution {
    static let logoHeight: CGFloat = 24  // × 3432/940 ≈ 88 pt wide

    /// Points reserved below the grid for the logo.
    public var bandHeight: CGFloat { self == .spotify ? Self.logoHeight * 2 : 0 }

    /// The logo centred in the band (band at y = 0, `aspect` = logo width / height), on whole pixels so it stays sharp.
    public func logoFrame(width: CGFloat, aspect: CGFloat, scale: CGFloat = 1) -> CGRect {
        func pixels(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let size = CGSize(width: pixels(Self.logoHeight * aspect), height: Self.logoHeight)
        return CGRect(x: pixels((width - size.width) / 2), y: (bandHeight - size.height) / 2, width: size.width, height: size.height)
    }

    /// Room for the band plus a grid above it, and for the logo with its clear space beside it; otherwise no covers.
    public func fits(width: CGFloat, height: CGFloat, aspect: CGFloat) -> Bool {
        bandHeight == 0 || (height > bandHeight && width >= Self.logoHeight * aspect + bandHeight / 2)
    }

    /// The bundled logo for this background: white on dark, black on light (the green one is only allowed on pure black/white).
    public func logoName(background: String) -> String? {
        guard self == .spotify else { return nil }
        let rgb = UInt32(background.dropFirst(), radix: 16) ?? 0
        let luma = 0.299 * Double(rgb >> 16 & 0xFF) + 0.587 * Double(rgb >> 8 & 0xFF) + 0.114 * Double(rgb & 0xFF)
        return luma < 128 ? "Spotify_Full_Logo_RGB_White" : "Spotify_Full_Logo_RGB_Black"
    }
}

extension SourcePolicy {
    public var cornerRadius: CGFloat { attribution == .spotify ? 8 : 0 }

    /// Attributed artwork must not be distorted, and a flip swings bottom covers through the logo's clear space: fade.
    public func transition(preferred: Transition) -> Transition { attribution == .none ? preferred : .fade }

    /// Where a cover goes in its tile: filling it (`.centerSquare`, already square-cropped), or a centred square so an
    /// uncropped (square) cover and its rounded corners line up.
    public func coverFrame(in tile: CGRect) -> CGRect {
        guard crop == .none else { return tile }
        let side = min(tile.width, tile.height)
        return CGRect(x: tile.midX - side / 2, y: tile.midY - side / 2, width: side, height: side)
    }
}
