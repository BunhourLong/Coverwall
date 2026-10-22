import Foundation
import Testing
import CoverwallKit

/// A fake `Coverwall.saver` with one file whose contents mark the version.
private func fakeSaver(at url: URL, version: String) throws {
    try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
    try Data(version.utf8).write(to: url.appendingPathComponent("Contents/version"))
}

private func version(_ saver: URL) throws -> String {
    String(decoding: try Data(contentsOf: saver.appendingPathComponent("Contents/version")), as: UTF8.self)
}

@Test func bundledSaverIsFoundInShareNextToTheRealBinary() throws {
    let root = try scratch().data
    // Homebrew layout: bin/coverwall is a symlink into the Cellar, the bundle sits in the Cellar's share/coverwall.
    let cellar = root.appendingPathComponent("Cellar/coverwall/1.0")
    let binary = cellar.appendingPathComponent("bin/coverwall"), link = root.appendingPathComponent("bin/coverwall")
    try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data().write(to: binary)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: binary)
    #expect(Installer.bundledSaver(executable: link) == nil)

    let saver = cellar.appendingPathComponent("share/coverwall/Coverwall.saver")
    try fakeSaver(at: saver, version: "1")
    // resolvingSymlinksInPath strips the /private prefix of the temp dir (SPIKE_NOTES Phase 2).
    #expect(Installer.bundledSaver(executable: link)?.path == saver.resolvingSymlinksInPath().path)
}

@Test func installCopiesTheBundleAndReplacesAnOlderOne() throws {
    let root = try scratch().data
    let new = root.appendingPathComponent("build/Coverwall.saver")
    let target = root.appendingPathComponent("Library/Screen Savers/Coverwall.saver")
    try fakeSaver(at: new, version: "2")

    try Installer.install(new, to: target)
    #expect(try version(target) == "2")

    try FileManager.default.removeItem(at: new)
    try fakeSaver(at: new, version: "3")
    try Data().write(to: target.appendingPathComponent("Contents/stale"))
    try Installer.install(new, to: target)
    #expect(try version(target) == "3")
    #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("Contents/stale").path))
    #expect(try version(new) == "3")
}

@Test func uninstallRemovesTheBundleAndSaysWhetherItWasThere() throws {
    let root = try scratch().data
    let target = root.appendingPathComponent("Library/Screen Savers/Coverwall.saver")
    try fakeSaver(at: target, version: "1")

    #expect(try Installer.uninstall(target))
    #expect(!FileManager.default.fileExists(atPath: target.path))
    #expect(try !Installer.uninstall(target))
}
