import Foundation
import Testing
import CoverwallKit

/// A store with one image in its source folder.
private func store() throws -> (Store, URL) {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)
    return (Store(dataDir: dirs.data), dirs.source)
}

@Test func addSavesProfileCachesTilesAndActivatesTheFirstOne() async throws {
    let (store, source) = try store()

    let report = try await store.add("mac", profile(source))
    _ = try await store.add("other", profile(source))

    #expect(report.images == 1)
    let config = try store.load()
    #expect(config.activeProfile == "mac")
    #expect(Set(config.profiles.keys) == ["mac", "other"])
    #expect(try Config.decode(Data(contentsOf: Paths.config(in: store.dataDir))) == config)
}

@Test func addRejectsDuplicateAndUnsafeNamesWithoutTouchingDisk() async throws {
    let (store, source) = try store()
    _ = try await store.add("mac", profile(source))
    await #expect(throws: StoreError.profileExists("mac")) { try await store.add("mac", profile(source)) }

    await #expect(throws: ConfigError.invalidProfileName("../evil")) { try await store.add("../evil", profile(source)) }
    #expect(!FileManager.default.fileExists(atPath: store.dataDir.appendingPathComponent("evil").path))
    #expect(try store.load().profiles.keys.sorted() == ["mac"])
}

@Test func useSwitchesTheActiveProfile() async throws {
    let (store, source) = try store()
    _ = try await store.add("mac", profile(source))
    _ = try await store.add("other", profile(source))

    try store.use("other")

    #expect(try store.load().activeProfile == "other")
    #expect(throws: StoreError.unknownProfile("nope")) { try store.use("nope") }
}

@Test func removingTheActiveProfileDeletesItsCacheAndLeavesNoneActive() async throws {
    let (store, source) = try store()
    _ = try await store.add("mac", profile(source))
    try FileManager.default.createDirectory(at: Paths.staging("mac", in: store.dataDir, id: "killed"), withIntermediateDirectories: true)

    try store.remove("mac")

    let config = try store.load()
    #expect(config.activeProfile == nil && config.profiles.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: Paths.profile("mac", in: store.dataDir).path))
    #expect(!FileManager.default.fileExists(atPath: Paths.staging("mac", in: store.dataDir, id: "killed").path))
    #expect(throws: StoreError.unknownProfile("mac")) { try store.remove("mac") }
}

@Test func updateResyncsOnlyWhenTileSizeChangesAndRejectsInvalidValues() async throws {
    let (store, source) = try store()
    _ = try await store.add("mac", profile(source))

    #expect(try await store.update(nil) { $0.grid = Grid(columns: 4, rows: 3) } == nil)
    #expect(try await store.update("mac") { $0.tileMaxPixels = 128 }?.images == 1)

    let saved = try #require(store.load().profiles["mac"])
    #expect(saved.grid == Grid(columns: 4, rows: 3) && saved.tileMaxPixels == 128)
    await #expect(throws: ConfigError.self) { try await store.update(nil) { $0.intervalSeconds = 0 } }
    #expect(try store.load().profiles["mac"] == saved)
}

@Test func syncAndUpdateNeedAnActiveProfileWhenNoNameIsGiven() async throws {
    let (store, source) = try store()
    await #expect(throws: StoreError.noActiveProfile) { try await store.sync(nil) }

    _ = try await store.add("mac", profile(source))
    try writeImage(source.appendingPathComponent("b.png"), width: 300, height: 300, shade: 0.1)
    #expect(try await store.sync(nil).added == 1)

    try store.remove("mac")
    await #expect(throws: StoreError.noActiveProfile) { try await store.update(nil) { $0.intervalSeconds = 2 } }
}

@Test func corruptConfigSaysWhichFileToFix() async throws {
    let (store, _) = try store()
    let config = Paths.config(in: store.dataDir)
    try FileManager.default.createDirectory(at: store.dataDir, withIntermediateDirectories: true)
    try Data("{ nope".utf8).write(to: config)
    #expect(throws: StoreError.corruptConfig(config.path)) { try store.load() }
}

@Test func unreadableConfigIsAnErrorSoItNeverGetsOverwritten() async throws {
    let (store, source) = try store()
    _ = try await store.add("mac", profile(source))
    let config = Paths.config(in: store.dataDir).path
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: config)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config) }

    await #expect(throws: (any Error).self) { try await store.add("other", profile(source)) }
}
