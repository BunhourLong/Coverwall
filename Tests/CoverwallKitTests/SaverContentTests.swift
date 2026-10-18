import Foundation
import Testing
import CoverwallKit

/// A data dir whose active profile "mac" has two cached tiles.
private func syncedDataDir() throws -> URL {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.2)
    try writeImage(dirs.source.appendingPathComponent("b.png"), width: 300, height: 300, shade: 0.8)
    _ = try Store(dataDir: dirs.data).add("mac", profile(dirs.source))
    return dirs.data
}

@Test func activeProfileLoadsWithItsCachedTiles() throws {
    let data = try syncedDataDir()

    guard case .ready(let loaded, let tiles) = SaverContent.load(from: data) else { Issue.record("not ready"); return }

    #expect(loaded.grid == Grid(columns: 7, rows: 5))
    #expect(tiles.count == 2)
    #expect(tiles.allSatisfy { FileManager.default.fileExists(atPath: $0.path) && $0.pathExtension == "jpg" })
}

@Test func missingOrProfilelessConfigSaysHowToAddOne() throws {
    let empty = try scratch().data
    #expect(SaverContent.load(from: empty) == .fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\""))

    let data = try syncedDataDir()
    var config = try Store(dataDir: data).load()
    config.activeProfile = nil
    try Store(dataDir: data).save(config)
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no profile — run \"coverwall add <name> <folder>\""))
}

@Test func corruptConfigPointsAtDoctor() throws {
    let data = try syncedDataDir()
    try Data("{ nope".utf8).write(to: Paths.config(in: data))
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: config.json is unreadable — run \"coverwall doctor\""))
}

@Test func missingCacheOrVanishedTilesSayHowToSync() throws {
    let data = try syncedDataDir()
    let tiles = try FileManager.default.contentsOfDirectory(at: Paths.tiles("mac", in: data), includingPropertiesForKeys: nil)
    try FileManager.default.removeItem(at: tiles[0])  // a tile vanishing under the saver is skipped
    guard case .ready(_, let left) = SaverContent.load(from: data) else { Issue.record("not ready"); return }
    #expect(left.count == 1)

    try FileManager.default.removeItem(at: tiles[1])
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no covers for 'mac' — run \"coverwall sync mac\""))
    try FileManager.default.removeItem(at: Paths.manifest("mac", in: data))
    #expect(SaverContent.load(from: data) == .fallback("Coverwall: no covers for 'mac' — run \"coverwall sync mac\""))
}
