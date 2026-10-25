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
    case noCoversLeft

    public var description: String {
        switch self {
        case .sourceMissing(let path): "folder '\(path)' not found — check the path (or reconnect the drive) and try again"
        case .noCoversLeft: "no cover could be read this time, so the existing covers are kept — check the source and sync again (`coverwall remove` clears a profile)"
        }
    }
}

/// CLI-only: a cover source → downsized JPEG tiles + manifest in the data dir (PLAN.md §3, §4.7).
public enum TileCache {
    public static func sync(_ name: String, profile: Profile, dataDir: URL = Paths.dataDir) async throws -> SyncReport {
        try await sync(name, from: LocalFolderSource(folder: profile.source), tileMaxPixels: profile.tileMaxPixels, dataDir: dataDir)
    }

    /// Builds a changed cache next to the live one and swaps it in at once, so the saver never sees a partial
    /// cache and a failed or killed sync leaves the old one intact (CLAUDE.md 10). An unchanged tile set only gets
    /// its manifest replaced — one atomic file write.
    public static func sync(_ name: String, from source: some CoverSource, tileMaxPixels: Int, dataDir: URL = Paths.dataDir,
                            now: Date = Date()) async throws -> SyncReport {
        let fm = FileManager.default, live = Paths.profile(name, in: dataDir), staging = Paths.staging(name, in: dataDir)
        // shortcut: also deletes the staging dir of a sync of this profile still running elsewhere (that one then fails);
        // add a lock once syncs run unattended (Phase 7.5).
        removeStaging(name, in: dataDir)
        try fm.createDirectory(at: staging.appendingPathComponent("tiles"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }  // after a swap this is the old cache
        let (report, manifest, reused) = try await build(staging, replacing: live, from: source, tileMaxPixels: tileMaxPixels, now: now)
        let json = try JSONEncoder().encode(manifest)
        if reused.count == manifest.tiles.count, report.removed == 0, fm.fileExists(atPath: live.path) {
            try json.write(to: live.appendingPathComponent("manifest.json"), options: .atomic)
            return report
        }
        for hash in reused { try fm.copyItem(at: Paths.tile(hash, inProfile: live), to: Paths.tile(hash, inProfile: staging)) }  // APFS clones
        try json.write(to: staging.appendingPathComponent("manifest.json"))  // last: marks the build complete
        if fm.fileExists(atPath: live.path) {
            // shortcut: RENAME_SWAP needs APFS/HFS+ (the container is APFS); other volumes fail with a bare POSIX error.
            guard renamex_np(staging.path, live.path, UInt32(RENAME_SWAP)) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        } else {
            try fm.moveItem(at: staging, to: live)
        }
        return report
    }

    /// New tiles go into `staging`; tiles that can stay are only listed (`reused`), so an unchanged sync copies nothing.
    private static func build(_ staging: URL, replacing live: URL, from source: some CoverSource, tileMaxPixels: Int,
                              now: Date) async throws -> (SyncReport, CacheManifest, reused: [String]) {
        let fm = FileManager.default
        let old = (try? JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: live.appendingPathComponent("manifest.json")))) ?? CacheManifest()
        // Same tile size and crop as last time: existing tiles stay, unchanged items aren't even read.
        let reusable = old.tileMaxPixels == tileMaxPixels && old.sourcePolicy.crop == source.policy.crop
        var known = reusable ? Dictionary(old.tiles.map { ($1, $0) }, uniquingKeysWith: { first, _ in first }) : [:]
        if reusable { for (source, dup) in old.duplicates ?? [:] { known[.init(source: source, mtime: dup.mtime)] = dup.hash } }
        var reused: [String] = []
        func reuse(_ hash: String) -> Bool {
            guard reusable, fm.fileExists(atPath: Paths.tile(hash, inProfile: live).path) else { return false }
            reused.append(hash)
            return true
        }
        var manifest = CacheManifest()
        manifest.tileMaxPixels = tileMaxPixels
        var report = SyncReport(), duplicates: [String: CacheManifest.Duplicate] = [:]
        // Known unchanged items are never read.
        let unchanged = { (item: CoverItem) in known[item].map { fm.fileExists(atPath: Paths.tile($0, inProfile: live).path) } ?? false }
        try await inOrder(try await source.items(), reading: source, unless: unchanged) { item, read in
            func duplicate(_ hash: String) { report.duplicates += 1; duplicates[item.source] = .init(mtime: item.mtime, hash: hash) }
            if let hash = known[item], manifest.tiles[hash] != nil { duplicate(hash); return }
            if let hash = known[item], reuse(hash) { manifest.tiles[hash] = item; return }
            if read?.skipped == true { report.skipped.append(item.source); return }
            guard let data = read?.data else { return }  // unchanged: handled above; nil: a track without a cover isn't an error
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if manifest.tiles[hash] != nil { duplicate(hash); return }
            if !reuse(hash) {
                guard let jpeg = tile(from: data, side: tileMaxPixels, crop: source.policy.crop) else { report.skipped.append(item.source); return }
                try jpeg.write(to: Paths.tile(hash, inProfile: staging))
            }
            manifest.tiles[hash] = item
        }
        // Nothing readable where there were covers: a dropped drive or a broken source, not a wish to empty the profile.
        if manifest.tiles.isEmpty, !old.tiles.isEmpty { throw TileCacheError.noCoversLeft }
        manifest.duplicates = duplicates.isEmpty ? nil : duplicates
        manifest.policy = source.policy
        manifest.syncedAt = now.timeIntervalSince1970
        manifest.expiresAt = source.policy.cacheTTL.map { now.timeIntervalSince1970 + $0 }
        report.images = manifest.tiles.count
        report.added = manifest.tiles.keys.filter { old.tiles[$0] == nil }.count
        report.removed = old.tiles.keys.filter { manifest.tiles[$0] == nil }.count
        return (report, manifest, reused)
    }

    /// One item's read: its bytes (`nil`: no cover), or skipped (`UnreadableCover`).
    struct Read: Sendable {
        var index: Int
        var data: Data?
        var skipped = false
    }

    /// Hands every item to `body` in order with its read (`nil` if `unless` said it needs none). Up to
    /// `source.maxConcurrentReads` reads run ahead at once; results wait for their turn, so dedupe stays deterministic.
    /// Any read error other than `UnreadableCover` ends the sync.
    // A plain struct as the child result: with a tuple holding an enum with `any Error`, release builds
    // (Swift 6.4) returned the same group result twice and lost the next one.
    private static func inOrder(_ items: [CoverItem], reading source: some CoverSource, unless unchanged: (CoverItem) -> Bool,
                                _ body: (CoverItem, Read?) throws -> Void) async throws {
        let limit = max(1, source.maxConcurrentReads)
        try await withThrowingTaskGroup(of: Read.self) { group in
            var done = 0, started = 0, ready: [Int: Read] = [:], unchangedItems = Set<Int>()
            while done < items.count {
                while started < items.count, started < done + limit {
                    let index = started, item = items[index]
                    started += 1
                    if unchanged(item) {
                        unchangedItems.insert(index)
                    } else {
                        group.addTask {
                            do { return Read(index: index, data: try await source.data(for: item)) } catch is UnreadableCover {
                                return Read(index: index, data: nil, skipped: true)
                            }
                        }
                    }
                }
                if unchangedItems.remove(done) != nil {
                    try body(items[done], nil)
                    done += 1
                } else if let read = ready.removeValue(forKey: done) {
                    try body(items[done], read)
                    done += 1
                } else {
                    // Item `done` is still being read, so the group can't be empty here.
                    guard let read = try await group.next() else { throw CancellationError() }
                    ready[read.index] = read
                }
            }
        }
    }

    /// Staging dirs of `name` left by failed or killed syncs.
    static func removeStaging(_ name: String, in dataDir: URL) {
        let prefix = Paths.staging(name, in: dataDir, id: "")
        for dir in (try? FileManager.default.contentsOfDirectory(at: prefix.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
        where dir.lastPathComponent.hasPrefix(prefix.lastPathComponent) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// `.centerSquare`: square, short side scaled to `side`; `.none`: whole image, long side scaled to `side`.
    /// Never upscaled, JPEG q0.85.
    static func tile(from data: Data, side: Int, crop: SourcePolicy.Crop) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
              min(width, height) > 0 else { return nil }
        // Thumbnails are sized by their long side; pick it so the short side lands on `side`.
        let longSide = crop == .none ? Double(side) : (Double(side) * Double(max(width, height)) / Double(min(width, height))).rounded(.up)
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longSide]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let square = min(image.width, image.height, side)
        guard let tile = crop == .none ? image
                : image.cropping(to: CGRect(x: (image.width - square) / 2, y: (image.height - square) / 2, width: square, height: square))
        else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, tile, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}
