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

private func hiddenProfileDirs(_ data: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: data.appendingPathComponent("profiles").path).filter { $0.hasPrefix(".") }
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
