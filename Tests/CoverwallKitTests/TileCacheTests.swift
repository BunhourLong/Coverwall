import Foundation
import ImageIO
import Testing
import CoverwallKit

/// Fresh source folder + data dir under the temp dir.
func scratch() throws -> (source: URL, data: URL) {
    // realpath: the enumerator reports /private/var, not the /var symlink.
    let temp = try #require(realpath(NSTemporaryDirectory(), nil))
    defer { free(temp) }
    let root = URL(fileURLWithPath: String(cString: temp)).appendingPathComponent("coverwall-tests-\(UUID().uuidString)")
    let source = root.appendingPathComponent("covers"), data = root.appendingPathComponent("data")
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    return (source, data)
}

/// Solid-colour PNG; `shade` makes the bytes (and so the hash) differ.
func writeImage(_ url: URL, width: Int, height: Int, shade: CGFloat) throws {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
    context.setFillColor(red: shade, green: 0.5, blue: 1 - shade, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
    #expect(CGImageDestinationFinalize(destination))
}

private func pixelSize(_ url: URL) throws -> (Int, Int) {
    let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    return (image.width, image.height)
}

func profile(_ source: URL, tileMax: Int = 512) -> Profile {
    Profile(source: source.path, grid: Grid(columns: 7, rows: 5), tileMaxPixels: tileMax)
}

@Test func syncCropsSquareTilesNoLargerThanTileMax() async throws {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("wide.png"), width: 1200, height: 800, shade: 0.1)
    try writeImage(dirs.source.appendingPathComponent("small.png"), width: 300, height: 300, shade: 0.9)

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report.images == 2 && report.added == 2 && report.removed == 0)
    let manifest = try JSONDecoder().decode(CacheManifest.self, from: Data(contentsOf: Paths.manifest("mac", in: dirs.data)))
    #expect(Set(manifest.tiles.values.map(\.source)) == [dirs.source.appendingPathComponent("wide.png").path,
                                                          dirs.source.appendingPathComponent("small.png").path])
    let sizes = try manifest.tiles.keys.map { try pixelSize(Paths.tiles("mac", in: dirs.data).appendingPathComponent("\($0).jpg")) }
    #expect(Set(sizes.map(\.0)) == [512, 300])            // never upscaled
    #expect(sizes.allSatisfy { $0.0 == $0.1 })             // square
}

@Test func syncDedupesAndReportsUnreadableFiles() async throws {
    let dirs = try scratch()
    let original = dirs.source.appendingPathComponent("a.png"), broken = dirs.source.appendingPathComponent("broken.jpg")
    try writeImage(original, width: 400, height: 400, shade: 0.2)
    try FileManager.default.createDirectory(at: dirs.source.appendingPathComponent("sub"), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: original, to: dirs.source.appendingPathComponent("sub/copy.PNG"))
    try Data("not an image".utf8).write(to: broken)
    try Data("ignored".utf8).write(to: dirs.source.appendingPathComponent("notes.txt"))

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report.images == 1 && report.duplicates == 1)
    #expect(report.skipped == [broken.path])
}

private func tileFiles(_ data: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: Paths.tiles("mac", in: data), includingPropertiesForKeys: nil)
}

private func modified(_ url: URL) throws -> Date? {
    try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

@Test func resyncKeepsUnchangedTilesAndDropsDeletedSources() async throws {
    let dirs = try scratch()
    let keep = dirs.source.appendingPathComponent("keep.png"), gone = dirs.source.appendingPathComponent("gone.png")
    try writeImage(keep, width: 300, height: 300, shade: 0.3)
    try writeImage(gone, width: 300, height: 300, shade: 0.7)
    _ = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)
    let before = try tileFiles(dirs.data).map(modified)

    let unchanged = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)
    #expect(unchanged == SyncReport(images: 2, added: 0, removed: 0, duplicates: 0, skipped: []))
    #expect(try tileFiles(dirs.data).map(modified) == before)   // not re-encoded

    try FileManager.default.removeItem(at: gone)
    let after = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)
    #expect(after.images == 1 && after.removed == 1 && after.added == 0)
    #expect(try tileFiles(dirs.data).count == 1)
}

@Test func changedTileMaxReencodesEveryTile() async throws {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 800, height: 800, shade: 0.4)
    _ = try await TileCache.sync("mac", profile: profile(dirs.source, tileMax: 512), dataDir: dirs.data)

    let report = try await TileCache.sync("mac", profile: profile(dirs.source, tileMax: 256), dataDir: dirs.data)

    #expect(report.added == 0)
    #expect(try tileFiles(dirs.data).map(pixelSize).map(\.0) == [256])
}

@Test func missingSourceFolderIsAnErrorNotAnEmptyProfile() async throws {
    let dirs = try scratch()
    let missing = dirs.source.appendingPathComponent("nope")
    await #expect(throws: TileCacheError.sourceMissing(missing.path)) {
        try await TileCache.sync("mac", profile: profile(missing), dataDir: dirs.data)
    }
}

/// Copies the encoder-made audio fixtures (ffmpeg: ID3v2.3/2.4 mp3, m4a `covr`, FLAC PICTURE) into `folder`.
private func copyFixtures(_ names: [String], to folder: URL) throws {
    let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    for name in names { try FileManager.default.copyItem(at: fixtures.appendingPathComponent(name), to: folder.appendingPathComponent(name)) }
}

@Test func syncTakesEmbeddedCoverArtFromMp3M4aAndFlac() async throws {
    let dirs = try scratch()
    try copyFixtures(["red.mp3", "green.m4a", "blue.flac"], to: dirs.source)

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report.images == 3 && report.skipped.isEmpty, "\(report)")
    #expect(try tileFiles(dirs.data).map(pixelSize).allSatisfy { $0 == (64, 64) })
}

@Test func tracksSharingAnAlbumCoverMakeOneTile() async throws {
    let dirs = try scratch()
    try copyFixtures(["red.mp3", "red-track2.mp3"], to: dirs.source)

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report.images == 1 && report.duplicates == 1)
}

@Test func tracksWithoutCoverArtAreIgnoredNotReportedAsSkipped() async throws {
    let dirs = try scratch()
    try copyFixtures(["no-art.mp3"], to: dirs.source)

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report == SyncReport())
}

@Test func truncatedAudioFilesNeverCrashOrMakeHalfDrawnTiles() async throws {
    let dirs = try scratch()
    let fixtures = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    for name in ["red.mp3", "red-track2.mp3", "green.m4a", "blue.flac"] {
        let bytes = try Data(contentsOf: fixtures.appendingPathComponent(name))
        for length in stride(from: 0, to: bytes.count, by: 7) {
            try bytes.prefix(length).write(to: dirs.source.appendingPathComponent("\(length)-\(name)"))
        }
    }

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    // A cut can still hold the whole picture (fine); a cut-short one must give no tile, not a half-drawn one.
    #expect(report.images <= 3)
    #expect(try tileFiles(dirs.data).map(pixelSize).allSatisfy { $0 == (64, 64) })
}

private func makeUnreadable(_ url: URL) throws {
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
}

@Test func unreadableAudioFilesAreReportedAsSkipped() async throws {
    let dirs = try scratch()
    try copyFixtures(["red.mp3"], to: dirs.source)
    try makeUnreadable(dirs.source.appendingPathComponent("red.mp3"))

    let report = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(report.skipped == [dirs.source.appendingPathComponent("red.mp3").path])
}

@Test func resyncDoesNotReReadUnchangedDuplicateTracks() async throws {
    let dirs = try scratch()
    try copyFixtures(["red.mp3", "red-track2.mp3"], to: dirs.source)
    _ = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)
    // red.mp3 sorts after red-track2.mp3, so it's the duplicate; a re-read would now be "skipped".
    try makeUnreadable(dirs.source.appendingPathComponent("red.mp3"))

    let again = try await TileCache.sync("mac", profile: profile(dirs.source), dataDir: dirs.data)

    #expect(again == SyncReport(images: 1, added: 0, removed: 0, duplicates: 1, skipped: []))
}
