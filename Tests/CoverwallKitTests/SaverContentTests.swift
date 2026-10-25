import Foundation
import Testing
import CoverwallKit

/// A data dir whose active profile "mac" has two cached tiles.
private func syncedDataDir() async throws -> URL {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.2)
    try writeImage(dirs.source.appendingPathComponent("b.png"), width: 300, height: 300, shade: 0.8)
    _ = try await Store(dataDir: dirs.data).add("mac", profile(dirs.source))
    return dirs.data
}

@Test func activeProfileLoadsWithItsCachedTiles() async throws {
    let data = try await syncedDataDir()

    guard case .ready("mac", let loaded, let tiles, _, _) = SaverContent.load(from: data) else { Issue.record("not ready"); return }

    #expect(loaded.grid == Grid(columns: 7, rows: 5))
    #expect(tiles.count == 2)
    #expect(tiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension == "jpg" })
}

@Test func missingOrProfilelessConfigSaysHowToAddOne() async throws {
    let empty = try scratch().data
    #expect(SaverContent.load(from: empty) == .fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\""))

    let data = try await syncedDataDir()
    var config = try Store(dataDir: data).load()
    config.activeProfile = nil
    try Store(dataDir: data).save(config)
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\""))
}

@Test func corruptConfigPointsAtDoctor() async throws {
    let data = try await syncedDataDir()
    try Data("{ nope".utf8).write(to: Paths.config(in: data))
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: config.json is unreadable — run \"coverwall doctor\""))
}

@Test func missingCacheOrVanishedTilesSayHowToSync() async throws {
    let data = try await syncedDataDir()
    let tiles = try FileManager.default.contentsOfDirectory(at: Paths.tiles("mac", in: data), includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: tiles[0])  // a tile vanishing under the saver is skipped
    guard case .ready(_, _, let left, _, _) = SaverContent.load(from: data) else { Issue.record("not ready"); return }
    #expect(left.count == 1)

    try FileManager.default.removeItem(at: tiles[1])
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no covers for 'mac' — run \"coverwall sync mac\""))
    try FileManager.default.removeItem(at: Paths.manifest("mac", in: data))
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no covers for 'mac' — run \"coverwall sync mac\""))
}

@Test func configureSheetSummaryShowsTheActiveProfile() async throws {
    let data = try await syncedDataDir()
    let source = try Store(dataDir: data).load().profiles["mac"]!.source

    #expect(SaverContent.summary(from: data) == """
        Active profile: mac
        Folder: \(source)
        Grid: 7x5 · every 4 s · flip
        2 covers
        Change it in Terminal: coverwall set, coverwall use <name>
        """)

    var config = try Store(dataDir: data).load()
    config.profiles["mac"]!.grid.rows = nil
    try Store(dataDir: data).save(config)
    #expect(SaverContent.summary(from: data).contains("Grid: 7 columns, rows fit the screen · every 4 s · flip"))

    config.profiles["mac"]!.heroes = 3
    try Store(dataDir: data).save(config)
    #expect(SaverContent.summary(from: data).contains("Grid: 7 columns, rows fit the screen · 3 heroes · every 4 s · flip"))
}

@Test func configureSheetSummaryWithoutAProfileIsTheFallbackMessage() async throws {
    #expect(SaverContent.summary(from: try scratch().data) == "Coverwall: no profile — run \"coverwall add <name> <folder>\"")
}

@Test func configureSheetLabelsANonFolderSourceAsSource() async throws {
    let data = try await syncedDataDir()
    var config = try Store(dataDir: data).load()
    config.profiles["mac"]!.source = "spotify:saved-albums"
    try Store(dataDir: data).save(config)

    #expect(SaverContent.summary(from: data).contains("\nSource: spotify:saved-albums\n"))
}
