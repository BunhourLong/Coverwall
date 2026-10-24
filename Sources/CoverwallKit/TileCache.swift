import CryptoKit
import Foundation
import ImageIO

/// What `sync` did, for `coverwall add/sync` output (PLAN.md §4.5).
public struct SyncReport: Codable, Equatable, Sendable {
    /// Tiles in the cache after the sync.
    public var images = 0
    public var added = 0
    public var removed = 0
    public var duplicates = 0
    /// Supported files that couldn't be read or decoded.
    public var skipped: [String] = []

    public init(images: Int = 0, added: Int = 0, removed: Int = 0, duplicates: Int = 0, skipped: [String] = []) {
        (self.images, self.added, self.removed, self.duplicates, self.skipped) = (images, added, removed, duplicates, skipped)
    }
}

public enum TileCacheError: Error, Equatable, CustomStringConvertible {
    case sourceMissing(String)

    public var description: String {
        switch self {
        case .sourceMissing(let path): "folder '\(path)' not found — check the path (or reconnect the drive) and try again"
        }
    }
}

/// CLI-only: source folder → square, downsized JPEG tiles + manifest in the data dir (PLAN.md §3).
public enum TileCache {
    static let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "tiff", "tif"]
    static let scanned = extensions.union(AudioArtwork.extensions)

    public static func sync(_ name: String, profile: Profile, dataDir: URL = Paths.dataDir) throws -> SyncReport {
        let fm = FileManager.default, tiles = Paths.tiles(name, in: dataDir), manifestURL = Paths.manifest(name, in: dataDir)
        var isFolder: ObjCBool = false
        guard fm.fileExists(atPath: profile.source, isDirectory: &isFolder), isFolder.boolValue else {
            throw TileCacheError.sourceMissing(profile.source)
        }
        func tile(_ hash: String) -> URL { Paths.tile(hash, of: name, in: dataDir) }
        try fm.createDirectory(at: tiles, withIntermediateDirectories: true)
        let old = (try? JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: manifestURL))) ?? CacheManifest()
        // Same tile size as last time: existing tiles stay, unchanged sources aren't even read.
        let reusable = old.tileMaxPixels == profile.tileMaxPixels
        var known = reusable ? Dictionary(old.tiles.map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        if reusable { for (source, dup) in old.duplicates ?? [:] { known[.init(source: source, mtime: dup.mtime)] = dup.hash } }
        var manifest = CacheManifest()
        manifest.tileMaxPixels = profile.tileMaxPixels
        var report = SyncReport(), duplicates: [String: CacheManifest.Duplicate] = [:]
        for file in sources(in: URL(fileURLWithPath: profile.source)) {
            let mtime = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let entry = CacheManifest.Tile(source: file.path, mtime: mtime)
            func duplicate(_ hash: String) { report.duplicates += 1; duplicates[file.path] = .init(mtime: mtime, hash: hash) }
            if let hash = known[entry], fm.fileExists(atPath: tile(hash).path) {
                // Known unchanged source: no read. Still a duplicate if an earlier source already claimed the tile.
                if manifest.tiles[hash] == nil { manifest.tiles[hash] = entry } else { duplicate(hash) }
                continue
            }
            let ext = file.pathExtension.lowercased(), isAudio = AudioArtwork.extensions.contains(ext)
            // Audio is mapped: only the tag's pages are read, not the whole track.
            guard var data = try? Data(contentsOf: file, options: isAudio ? .alwaysMapped : []) else {
                report.skipped.append(file.path); continue
            }
            if isAudio {
                guard let art = AudioArtwork.picture(in: data, ext: ext) else { continue }   // a track without a cover isn't an error
                data = art   // tracks of one album share these bytes, so dedupe keeps one tile per album
            }
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if manifest.tiles[hash] != nil { duplicate(hash); continue }
            if !(reusable && fm.fileExists(atPath: tile(hash).path)) {
                guard let jpeg = Self.tile(from: data, side: profile.tileMaxPixels) else { report.skipped.append(file.path); continue }
                try jpeg.write(to: tile(hash), options: .atomic)
            }
            manifest.tiles[hash] = entry
        }
        manifest.duplicates = duplicates.isEmpty ? nil : duplicates
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        let keep = Set(manifest.tiles.keys.map { "\($0).jpg" })
        for file in (try? fm.contentsOfDirectory(at: tiles, includingPropertiesForKeys: nil)) ?? [] where !keep.contains(file.lastPathComponent) {
            try? fm.removeItem(at: file)
        }
        report.images = manifest.tiles.count
        report.added = manifest.tiles.keys.filter { old.tiles[$0] == nil }.count
        report.removed = old.tiles.keys.filter { manifest.tiles[$0] == nil }.count
        return report
    }

    /// Supported images and audio files under `folder`, recursively, sorted so dedupe keeps the same original.
    static func sources(in folder: URL) -> [URL] {
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (files?.compactMap { $0 as? URL } ?? [])
            .filter { scanned.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }

    /// Center-cropped square, short side scaled to `side` (never up), JPEG q0.85.
    static func tile(from data: Data, side: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) > 0 else { return nil }
        // Thumbnails are sized by their long side; pick it so the short side lands on `side`.
        let longSide = (Double(side) * Double(max(width, height)) / Double(min(width, height))).rounded(.up)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let crop = min(image.width, image.height, side)
        guard let square = image.cropping(to: CGRect(x: (image.width - crop) / 2, y: (image.height - crop) / 2, width: crop, height: crop))
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, square, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
