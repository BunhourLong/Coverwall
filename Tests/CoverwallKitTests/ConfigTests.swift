import Foundation
import Testing
import CoverwallKit

let sampleJSON = """
{
  "version": 1,
  "activeProfile": "macmiller",
  "profiles": {
    "macmiller": {
      "source": "/Users/capon/Documents/MacMiller",
      "grid": { "columns": 7, "rows": 5 },
      "intervalSeconds": 4,
      "swapsPerTick": 1,
      "transition": "flip",
      "tileMaxPixels": 1024,
      "background": "#000000",
      "gapPoints": 0
    }
  }
}
"""

@Test func decodesSampleConfig() throws {
    let config = try Config.decode(Data(sampleJSON.utf8))
    #expect(config.activeProfile == "macmiller")
    let profile = try #require(config.active)
    #expect(profile.source == "/Users/capon/Documents/MacMiller")
    #expect(profile.grid == Grid(columns: 7, rows: 5))
    #expect(profile.intervalSeconds == 4)
    #expect(profile.swapsPerTick == 1)
    #expect(profile.transition == .flip)
    #expect(profile.tileMaxPixels == 1024)
    #expect(profile.background == "#000000")
    #expect(profile.gapPoints == 0)
}

/// Field named in the validation error after replacing `old` with `new` in the sample.
private func invalidField(_ old: String, _ new: String) throws -> String? {
    let json = sampleJSON.replacingOccurrences(of: old, with: new)
    #expect(json != sampleJSON, "replacement \(old) not found")
    do {
        _ = try Config.decode(Data(json.utf8))
        return nil
    } catch let ConfigError.invalid(profile, field, _) {
        #expect(profile == "macmiller")
        return field
    }
}

@Test(arguments: [
    (#""columns": 7"#, #""columns": 0"#, "grid"),
    (#""rows": 5"#, #""rows": 17"#, "grid"),
    (#""intervalSeconds": 4"#, #""intervalSeconds": 0"#, "intervalSeconds"),
    (#""swapsPerTick": 1"#, #""swapsPerTick": 0"#, "swapsPerTick"),
    (#""swapsPerTick": 1"#, #""swapsPerTick": 36"#, "swapsPerTick"),
    (#""tileMaxPixels": 1024"#, #""tileMaxPixels": 0"#, "tileMaxPixels"),
    (##""#000000""##, #""black""#, "background"),
    (##""#000000""##, ##""#00000G""##, "background"),
    (#""gapPoints": 0"#, #""gapPoints": -1"#, "gapPoints"),
    (#""source": "/Users/capon/Documents/MacMiller""#, #""source": "relative/path""#, "source"),
])
func rejectsInvalidProfileValues(old: String, new: String, field: String) throws {
    #expect(try invalidField(old, new) == field)
}

@Test func rejectsUnknownActiveProfile() {
    let json = sampleJSON.replacingOccurrences(of: #""activeProfile": "macmiller""#, with: #""activeProfile": "nope""#)
    #expect(throws: ConfigError.unknownActiveProfile("nope")) { try Config.decode(Data(json.utf8)) }
}

@Test func rejectsNewerVersion() {
    let json = sampleJSON.replacingOccurrences(of: #""version": 1"#, with: #""version": 2"#)
    #expect(throws: ConfigError.unsupportedVersion(2)) { try Config.decode(Data(json.utf8)) }
}

@Test(arguments: ["", "../evil", "a/b", "Mac Miller", ".hidden"])
func rejectsUnsafeProfileNames(name: String) {
    let json = sampleJSON.replacingOccurrences(of: "\"macmiller\"", with: "\"\(name)\"")
    #expect(throws: ConfigError.invalidProfileName(name)) { try Config.decode(Data(json.utf8)) }
}

@Test func columnsOnlyGridLeavesRowsToTheScreen() throws {
    let json = sampleJSON.replacingOccurrences(of: #"{ "columns": 7, "rows": 5 }"#, with: #"{ "columns": 7 }"#)
    let profile = try #require(Config.decode(Data(json.utf8)).active)
    #expect(profile.grid == Grid(columns: 7, rows: nil))
}

@Test func parsesGridArgument() {
    #expect(Grid(parsing: "7x5") == Grid(columns: 7, rows: 5))
    #expect(Grid(parsing: "1X1") == Grid(columns: 1, rows: 1))
}

/// Range is left to `Config.validate`; parsing only rejects the shape.
@Test(arguments: ["7", "7x", "x5", "7x5x2", " 7x5", "-1x5", "axb", ""])
func rejectsMalformedGridArgument(text: String) {
    #expect(Grid(parsing: text) == nil)
}
