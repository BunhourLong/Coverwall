import Foundation
import Testing
import CoverwallKit

private final class Marker {}

/// Runs the built `coverwall` against `data` (via `COVERWALL_DATA_DIR`).
private func coverwall(_ arguments: String..., data: URL) throws -> (status: Int32, out: String, err: String) {
    let process = Process(), out = Pipe(), err = Pipe()
    process.executableURL = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("coverwall")
    process.arguments = arguments
    process.environment = ["COVERWALL_DATA_DIR": data.path]
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

@Test func installWithoutABuiltSaverSaysHowToGetOne() throws {
    // The test binary has no ../share/coverwall, so this fails before touching ~/Library or the host.
    let install = try coverwall("install", data: try scratch().data)
    #expect(install.status != 0 && install.err.contains("make install"), "\(install.err)")
}
