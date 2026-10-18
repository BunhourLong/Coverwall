import Foundation
import Testing
import CoverwallKit

/// A store with one image in its source folder.
private func store() throws -> (Store, URL) {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)
    return (Store(dataDir: dirs.data), dirs.source)
}

@Test func addSavesProfileCachesTilesAndActivatesTheFirstOne() throws {
    let (store, source) = try store()

    let report = try store.add("mac", profile(source))
    _ = try store.add("other", profile(source))

    #expect(report.images == 1)
    let config = try store.load()
    #expect(config.activeProfile == "mac")
    #expect(Set(config.profiles.keys) == ["mac", "other"])
    #expect(try Config.decode(Data(contentsOf: Paths.config(in: store.dataDir))) == config)
}

@Test func addRejectsDuplicateAndUnsafeNamesWithoutTouchingDisk() throws {
    let (store, source) = try store()
    _ = try store.add("mac", profile(source))
    #expect(throws: StoreError.profileExists("mac")) { try store.add("mac", profile(source)) }

    #expect(throws: ConfigError.invalidProfileName("../evil")) { try store.add("../evil", profile(source)) }
    #expect(!FileManager.default.fileExists(atPath: store.dataDir.appendingPathComponent("evil").path))
    #expect(try store.load().profiles.keys.sorted() == ["mac"])
}

@Test func useSwitchesTheActiveProfile() throws {
    let (store, source) = try store()
    _ = try store.add("mac", profile(source))
    _ = try store.add("other", profile(source))

    try store.use("other")

    #expect(try store.load().activeProfile == "other")
    #expect(throws: StoreError.unknownProfile("nope")) { try store.use("nope") }
}

@Test func removingTheActiveProfileDeletesItsCacheAndLeavesNoneActive() throws {
    let (store, source) = try store()
    _ = try store.add("mac", profile(source))

    try store.remove("mac")

    let config = try store.load()
    #expect(config.activeProfile == nil && config.profiles.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: Paths.profile("mac", in: store.dataDir).path))
    #expect(throws: StoreError.unknownProfile("mac")) { try store.remove("mac") }
}

@Test func updateResyncsOnlyWhenTileSizeChangesAndRejectsInvalidValues() throws {
    let (store, source) = try store()
    _ = try store.add("mac", profile(source))

    #expect(try store.update(nil) { $0.grid = Grid(columns: 4, rows: 3) } == nil)
    #expect(try store.update("mac") { $0.tileMaxPixels = 128 }?.images == 1)

    let saved = try #require(store.load().profiles["mac"])
    #expect(saved.grid == Grid(columns: 4, rows: 3) && saved.tileMaxPixels == 128)
    #expect(throws: ConfigError.self) { try store.update(nil) { $0.intervalSeconds = 0 } }
    #expect(try store.load().profiles["mac"] == saved)
}

@Test func syncAndUpdateNeedAnActiveProfileWhenNoNameIsGiven() throws {
    let (store, source) = try store()
    #expect(throws: StoreError.noActiveProfile) { try store.sync(nil) }

    _ = try store.add("mac", profile(source))
    try writeImage(source.appendingPathComponent("b.png"), width: 300, height: 300, shade: 0.1)
    #expect(try store.sync(nil).added == 1)

    try store.remove("mac")
    #expect(throws: StoreError.noActiveProfile) { try store.update(nil) { $0.intervalSeconds = 2 } }
}

@Test func corruptConfigSaysWhichFileToFix() throws {
    let (store, _) = try store()
    let config = Paths.config(in: store.dataDir)
    try FileManager.default.createDirectory(at: store.dataDir, withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: config)
    #expect(throws: StoreError.corruptConfig(config.path)) { try store.load() }
}

@Test func unreadableConfigIsAnErrorSoItNeverGetsOverwritten() throws {
    let (store, source) = try store()
    _ = try store.add("mac", profile(source))
    let config = Paths.config(in: store.dataDir).path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config) }

    #expect(throws: (any Error).self) { try store.add("other", profile(source)) }
}
