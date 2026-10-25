import Foundation
import ImageIO
import Testing
import CoverwallKit

private struct StubError: Error {}

/// A non-folder source (stands in for Spotify): fixed covers, or a failing listing.
private struct StubSource: CoverSource {
    var policy: SourcePolicy
    var covers: [String: Data] = [:]
    var failing = false

    func items() async throws -> [CoverItem] {
        if failing { throw StubError() }
        return covers.keys.sorted().map { CoverItem(source: $0, mtime: 0) }
    }

    func data(for item: CoverItem) async throws -> Data? { covers[item.source] }
}

private let remote = SourcePolicy(crop: .none, attribution: .spotify, cacheTTL: 3600, mixable: false)
private let now = Date(timeIntervalSince1970: 1_000_000)

private func png(width: Int, height: Int, shade: CGFloat) throws -> Data {
    let url = try scratch().source.appendingPathComponent("x.png")
    try writeImage(url, width: width, height: height, shade: shade)
    return try Data(contentsOf: url)
}

private func manifest(_ data: URL) throws -> CacheManifest {
    try JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: Paths.manifest("mac", in: data)))
}

/// Staging dirs left in `profiles/` (the sync lock files are expected to stay).
private func hiddenProfileDirs(_ data: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("profiles").path).filter { $0.contains(".tmp-") }
}

@Test func manifestsWithoutAPolicyAreLocalFolderCaches() throws {
    let json = #"{"version":1,"tileMaxPixels":512,"tiles":{}}"#
    let old = try JSONDecoder().decode(CacheManifest.self, from: Data(json.utf8))
    #expect(old.sourcePolicy == SourcePolicy(crop: .centerSquare, attribution: .none, cacheTTL: nil, mixable: true))
    #expect(old.expiresAt == nil)
}

@Test func syncWritesThePolicyAndWhenTheCacheExpires() async throws {
    let dirs = try scratch()
    let source = StubSource(policy: remote, covers: ["https://i.example/a": try png(width: 300, height: 300, shade: 0.2)])

    let report = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)

    #expect(report.images == 1)
    let written = try manifest(dirs.data)
    #expect(written.policy == remote)
    #expect(written.syncedAt == 1_000_000 && written.expiresAt == 1_003_600)

    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)
    _ = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)
    #expect(try manifest(dirs.data).sourcePolicy == .localFolder && manifest(dirs.data).expiresAt == nil)
}

@Test func uncroppedPolicyResizesWithoutCropping() async throws {
    let dirs = try scratch()
    let source = StubSource(policy: remote, covers: ["https://i.example/wide": try png(width: 1200, height: 800, shade: 0.3)])

    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)

    let hash = try #require(manifest(dirs.data).tiles.keys.first)
    let image = try #require(CGImageSourceCreateWithURL(Paths.tile(hash, of: "mac", in: dirs.data) as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(image.width == 512 && (341...342).contains(image.height))
}

@Test func failedSyncKeepsTheOldCacheAndLeavesNoTempDir() async throws {
    let dirs = try scratch()
    var source = StubSource(policy: remote, covers: ["https://i.example/a": try png(width: 300, height: 300, shade: 0.2),
                                                     "https://i.example/b": try png(width: 300, height: 300, shade: 0.7)])
    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)
    let before = try manifest(dirs.data)

    source.failing = true
    await #expect(throws: StubError.self) {
        try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now.addingTimeInterval(60))
    }

    #expect(try manifest(dirs.data) == before)
    #expect(before.tiles.keys.allSatisfy { FileManager.default.fileExists(atPath: Paths.tile($0, of: "mac", in: dirs.data).path) })
    #expect(try hiddenProfileDirs(dirs.data).isEmpty)
}

@Test func tempDirLeftByAKilledSyncIsRemovedByTheNextOne() async throws {
    let dirs = try scratch()
    let leftover = dirs.data.appendingPathComponent("profiles/.mac.tmp-killed/tiles")
    try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)

    _ = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(try hiddenProfileDirs(dirs.data).isEmpty)
    #expect(try manifest(dirs.data).tiles.count == 1)
}

/// Data dir whose active profile "mac" was synced from `source` at `syncedAt`.
private func activeProfile(from source: StubSource, syncedAt: Date) async throws -> URL {
    let dirs = try scratch()
    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: syncedAt)
    var config = Config()
    config.profiles["mac"] = profile(dirs.source)
    config.activeProfile = "mac"
    try Store(dataDir: dirs.data).save(config)
    return dirs.data
}

@Test func saverGetsThePolicyAndExpiryFromTheManifest() async throws {
    let source = StubSource(policy: remote, covers: ["https://i.example/a": try png(width: 300, height: 300, shade: 0.2)])
    let data = try await activeProfile(from: source, syncedAt: now)

    guard case .ready(_, _, let tiles, let policy, let expiresAt) = SaverContent.load(from: data, now: now) else {
        Issue.record("not ready"); return
    }
    #expect(tiles.count == 1 && policy == remote && expiresAt == Date(timeIntervalSince1970: 1_003_600))
}

@Test func expiredCacheShowsTheFallbackNotStaleCovers() async throws {
    let source = StubSource(policy: remote, covers: ["https://i.example/a": try png(width: 300, height: 300, shade: 0.2)])
    let data = try await activeProfile(from: source, syncedAt: now)

    #expect(SaverContent.load(from: data, now: now.addingTimeInterval(3600))
            == .fallback("Coverwall: covers for 'mac' have expired — run \"coverwall sync mac\""))
}

@Test func syncLeavesOtherProfilesStagingDirsAlone() async throws {
    let dirs = try scratch()
    let other = dirs.data.appendingPathComponent("profiles/.mac-other.tmp-running")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)

    _ = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(FileManager.default.fileExists(atPath: other.path))
}

@Test func unchangedResyncStillRenewsTheExpiry() async throws {
    let dirs = try scratch()
    let source = StubSource(policy: remote, covers: ["https://i.example/a": try png(width: 300, height: 300, shade: 0.2)])
    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)

    let report = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now.addingTimeInterval(600))

    #expect(report == SyncReport(images: 1))
    #expect(try manifest(dirs.data).expiresAt == 1_004_200)
}

@Test func changedCropReencodesTilesOfTheSameSize() async throws {
    let dirs = try scratch()
    var source = StubSource(policy: remote, covers: ["https://i.example/wide": try png(width: 1200, height: 800, shade: 0.3)])
    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)

    source.policy.crop = .centerSquare
    _ = try await TileCache.sync("mac", from: source, tileMaxPixels: 512, dataDir: dirs.data, now: now)

    let hash = try #require(manifest(dirs.data).tiles.keys.first)
    let image = try #require(CGImageSourceCreateWithURL(Paths.tile(hash, of: "mac", in: dirs.data) as CFURL, nil)
        .flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect(image.width == image.height)
}

/// Counts how many `data(for:)` calls overlap; each one takes a moment, like a download.
private final class Downloads: CoverSource, @unchecked Sendable {
    let policy = remote
    let maxConcurrentReads: Int
    let covers: [String: Data]
    var failing: Set<String> = [], unreadable: Set<String> = [], slow: Set<String> = []
    private let lock = NSLock()
    private var running = 0
    private(set) var peak = 0, reads: [String] = []

    init(_ covers: [String: Data], concurrency: Int) { (self.covers, maxConcurrentReads) = (covers, concurrency) }

    func items() async throws -> [CoverItem] { covers.keys.sorted().map { CoverItem(source: $0, mtime: 0) } }

    func data(for item: CoverItem) async throws -> Data? {
        lock.withLock { running += 1; peak = max(peak, running); reads.append(item.source) }
        defer { lock.withLock { running -= 1 } }
        try await Task.sleep(for: .milliseconds(slow.contains(item.source) ? 60 : 10))
        if failing.contains(item.source) { throw StubError() }
        if unreadable.contains(item.source) { throw UnreadableCover() }
        return covers[item.source]
    }
}

private func covers(_ count: Int) throws -> [String: Data] {
    let image = try png(width: 64, height: 64, shade: 0.5)
    // Distinct bytes per cover (so no dedupe): append a trailing byte, which ImageIO ignores.
    return Dictionary(uniqueKeysWithValues: (0..<count).map { (String(format: "https://i.example/%02d", $0), image + Data([UInt8($0)])) })
}

@Test func readsRunConcurrentlyUpToTheSourcesLimitAndKeepTheirOrder() async throws {
    let dirs = try scratch()
    let source = Downloads(try covers(20), concurrency: 6)

    let report = try await TileCache.sync("mac", from: source, tileMaxPixels: 64, dataDir: dirs.data, now: now)

    #expect(report.images == 20)
    #expect(source.peak == 6)
    let sources = try manifest(dirs.data).tiles.values.map(\.source).sorted()
    #expect(sources == source.covers.keys.sorted())
}

@Test func resyncOnlyReadsNewCovers() async throws {
    let dirs = try scratch()
    var all = try covers(5)
    _ = try await TileCache.sync("mac", from: Downloads(all.filter { $0.key < "https://i.example/03" }, concurrency: 6),
                                 tileMaxPixels: 64, dataDir: dirs.data, now: now)
    let source = Downloads(all, concurrency: 6)
    all.removeAll()

    let report = try await TileCache.sync("mac", from: source, tileMaxPixels: 64, dataDir: dirs.data, now: now)

    #expect(report.added == 2 && report.images == 5)
    #expect(source.reads.sorted() == ["https://i.example/03", "https://i.example/04"])
}

@Test func unreadableCoverIsSkippedButAFailedReadAbortsAndKeepsTheCache() async throws {
    let dirs = try scratch()
    let first = Downloads(try covers(3), concurrency: 6)
    first.unreadable = ["https://i.example/01"]
    let report = try await TileCache.sync("mac", from: first, tileMaxPixels: 64, dataDir: dirs.data, now: now)
    #expect(report.images == 2 && report.skipped == ["https://i.example/01"])
    let before = try manifest(dirs.data)

    let offline = Downloads(try covers(4), concurrency: 6)
    offline.failing = ["https://i.example/03"]
    await #expect(throws: StubError.self) { try await TileCache.sync("mac", from: offline, tileMaxPixels: 64, dataDir: dirs.data, now: now) }

    #expect(try manifest(dirs.data) == before)
    #expect(try hiddenProfileDirs(dirs.data).isEmpty)
}

@Test func concurrentReadsStillDedupeInItemOrder() async throws {
    let dirs = try scratch()
    var all = try covers(6)
    all["https://i.example/05"] = all["https://i.example/00"]  // same cover twice
    let source = Downloads(all, concurrency: 6)
    source.slow = ["https://i.example/00"]  // the first one finishes last

    let report = try await TileCache.sync("mac", from: source, tileMaxPixels: 64, dataDir: dirs.data, now: now)

    #expect(report.images == 5 && report.duplicates == 1)
    let written = try manifest(dirs.data)
    #expect(written.tiles.values.contains { $0.source == "https://i.example/00" })
    #expect(written.duplicates?.keys.sorted() == ["https://i.example/05"])
}

@Test func syncThatWouldEmptyACacheWithCoversFailsAndKeepsThem() async throws {
    let dirs = try scratch()
    _ = try await TileCache.sync("mac", from: Downloads(try covers(2), concurrency: 6), tileMaxPixels: 64, dataDir: dirs.data, now: now)
    let before = try manifest(dirs.data)
    let gone = Downloads(try covers(2), concurrency: 6)
    gone.unreadable = ["https://i.example/00", "https://i.example/01"]  // e.g. a NAS dropped mid-sync

    await #expect(throws: TileCacheError.noCoversLeft) {
        try await TileCache.sync("mac", from: gone, tileMaxPixels: 128, dataDir: dirs.data, now: now)
    }
    #expect(try manifest(dirs.data) == before)
}

@Test func overlappingSyncsOfOneProfileTakeTurns() async throws {
    let dirs = try scratch()
    // Different tile sizes, so neither can reuse the other's tiles: both really build.
    async let first = TileCache.sync("mac", from: Downloads(try covers(20), concurrency: 1), tileMaxPixels: 64, dataDir: dirs.data, now: now)
    try await Task.sleep(for: .milliseconds(30))
    async let second = TileCache.sync("mac", from: Downloads(try covers(20), concurrency: 1), tileMaxPixels: 32, dataDir: dirs.data, now: now)

    #expect(try await first.images == 20)
    #expect(try await second.images == 20)
    #expect(try [32, 64].contains(manifest(dirs.data).tileMaxPixels) && hiddenProfileDirs(dirs.data).isEmpty)  // either order
}
