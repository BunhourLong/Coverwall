import Foundation
import Testing
import CoverwallKit

private final class Marker {}

/// Runs the built `coverwall` against `data` (via `COVERWALL_DATA_DIR`); secrets go to a file next to it, never the Keychain.
private func coverwall(_ arguments: String..., data: URL) throws -> (status: Int32, out: String, err: String) {
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("coverwall")
    process.arguments = arguments
    process.environment = ["COVERWALL_DATA_DIR": data.path, "COVERWALL_CLI_DIR": data.appendingPathComponent("../cli").standardized.path]
    (process.standardOutput, process.standardError) = (out, err)
    try process.run()
    process.waitUntilExit()
    let text = { (pipe: Pipe) in String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self) }
    return (process.terminationStatus, text(out), text(err))
}

@Test func addPrintsJSONReportAndListShowsTheActiveProfile() throws {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)

    let add = try coverwall("add", "mac", dirs.source.path, "--grid", "4x3", "--json", data: dirs.data)
    #expect(add.status == 0, "\(add.err)")
    let report = try JSONDecoder().decode(SyncReport.self, from: Data(add.out.utf8))
    #expect(report.images == 1)

    let list = try coverwall("list", data: dirs.data)
    #expect(list.status == 0 && list.out.hasPrefix("* mac"))
}

@Test func errorsExitNonZeroAndSayWhatToDoNext() throws {
    let dirs = try scratch()

    let use = try coverwall("use", "nope", data: dirs.data)
    #expect(use.status != 0 && use.err.contains("coverwall list"), "\(use.err)")

    let both = try coverwall("add", "mac", dirs.source.path, "--grid", "7x5", "--columns", "4", data: dirs.data)
    #expect(both.status != 0 && both.err.contains("--grid or --columns"), "\(both.err)")

    let grid = try coverwall("add", "mac", dirs.source.path, "--grid", "7by5", data: dirs.data)
    #expect(grid.status != 0 && grid.err.contains("7by5"), "\(grid.err)")

    let missing = try coverwall("add", "mac", dirs.source.appendingPathComponent("nope").path, data: dirs.data)
    #expect(missing.status != 0 && missing.err.contains("not found"), "\(missing.err)")
}

@Test func heroesAreStoredAndRecomputeTheTileSize() throws {
    let dirs = try scratch()
    try writeImage(dirs.source.appendingPathComponent("a.png"), width: 300, height: 300, shade: 0.5)
    #expect(try coverwall("add", "mac", dirs.source.path, "--tile-max", "100", data: dirs.data).status == 0)

    let set = try coverwall("set", "mac", "--heroes", "3", data: dirs.data)
    #expect(set.status == 0 && set.out.contains("7x5 + 3 heroes"), "\(set.out) \(set.err)")
    let sync = try coverwall("sync", "mac", data: dirs.data)
    #expect(sync.out.contains("7x5 + 3 heroes grid, 26 visible"), "\(sync.out)")  // 35 cells − 3 × 3
    let profile = try #require(try Store(dataDir: dirs.data).load().profiles["mac"])
    #expect(profile.heroes == 3)
    #expect(profile.tileMaxPixels != 100)  // recomputed at hero size, cache re-encoded
}

@Test func installWithoutABuiltSaverSaysHowToGetOne() throws {
    // The test binary has no ../share/coverwall, so this fails before touching ~/Library or the host.
    let install = try coverwall("install", data: try scratch().data)
    #expect(install.status != 0 && install.err.contains("make install") && install.err.contains("brew reinstall coverwall"), "\(install.err)")
}

@Test func spotifySetupStoresTheClientIDPrivatelyAndLogoutAllForgetsIt() throws {
    let data = try scratch().data
    let id = "0123456789abcdef0123456789abcdef"

    let bad = try coverwall("spotify", "setup", "--client-id", "nope", data: data)
    #expect(bad.status == 1 && bad.err.contains("doesn't look like a Client ID"))

    let setup = try coverwall("spotify", "setup", "--client-id", id, data: data)
    #expect(setup.status == 0, "\(setup.err)")
    let warning = try #require(setup.out.range(of: "Premium")), dashboard = try #require(setup.out.range(of: "developer.spotify.com/dashboard"))
    #expect(warning.lowerBound < dashboard.lowerBound)  // the Premium warning comes before any dashboard step
    #expect(setup.out.contains("http://127.0.0.1/callback"))

    let status = try coverwall("spotify", "status", "--json", data: data)
    #expect(status.status == 0 && status.out.contains("\"clientID\" : true") && status.out.contains("\"loggedIn\" : false"))
    let secrets = data.appendingPathComponent("../cli/secrets.json").standardized
    #expect(try String(contentsOf: secrets, encoding: .utf8).contains(id))
    let dataFiles = FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
    #expect(dataFiles.allSatisfy { !((try? String(contentsOf: $0, encoding: .utf8))?.contains(id) ?? false) })

    #expect(try coverwall("spotify", "logout", "--all", data: data).status == 0)
    #expect(try coverwall("spotify", "status", "--json", data: data).out.contains("\"clientID\" : false"))
}

@Test func spotifyLoginWithoutSetupSaysToRunSetup() throws {
    let login = try coverwall("spotify", "login", data: try scratch().data)
    #expect(login.status == 1 && login.err.contains("coverwall spotify setup"))
}

@Test func addingASpotifySourceNeedsSetupAndLoginAndAKnownKind() throws {
    let data = try scratch().data
    let noSetup = try coverwall("add", "sp", "spotify:saved-albums", data: data)
    #expect(noSetup.status == 1 && noSetup.err.contains("coverwall spotify setup"), "\(noSetup.err)")

    #expect(try coverwall("spotify", "setup", "--client-id", "0123456789abcdef0123456789abcdef", data: data).status == 0)
    let noLogin = try coverwall("add", "sp", "spotify:saved-albums", data: data)
    #expect(noLogin.status == 1 && noLogin.err.contains("coverwall spotify login"), "\(noLogin.err)")

    let unknown = try coverwall("add", "sp", "spotify:liked", data: data)
    #expect(unknown.status == 1 && unknown.err.contains("unknown source"))
    let missing = try coverwall("add", "sp", "spotify:artist", data: data)
    #expect(missing.status == 1 && missing.err.contains("which artist"))
    let folderWithExtra = try coverwall("add", "sp", data.path, "extra", data: data)
    #expect(folderWithExtra.status != 0 && folderWithExtra.err.contains("only for spotify:"))

    #expect(!FileManager.default.fileExists(atPath: Paths.config(in: data).path))  // nothing half-added
}

@Test func doctorAndSheetDescribeASpotifyProfileAsASourceNotAMissingFolder() throws {
    let data = try scratch().data
    var config = Config()
    config.profiles["sp"] = Profile(source: "spotify:top-artists")
    config.activeProfile = "sp"
    try Store(dataDir: data).save(config)

    let doctor = try coverwall("doctor", data: data)
    #expect(doctor.out.contains("profile sp: 0 tiles — run `coverwall sync sp`") && !doctor.out.contains("folder missing"), "\(doctor.out)")
    #expect(SaverContent.summary(from: data).contains("no covers for 'sp'"))  // no cache yet: the fallback, not a broken path
}
