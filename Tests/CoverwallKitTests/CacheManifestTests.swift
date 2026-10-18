import Foundation
import Testing
import CoverwallKit

@Test func manifestRoundTripsItsOnDiskFormat() throws {
    let json = #"{"version":1,"tiles":{"9f86d0":{"source":"/Users/capon/Documents/MacMiller/swimming.jpg","mtime":1760800000.25}}}"#
    let manifest = try JSONDecoder().decode(CacheManifest.self, from: Data(json.utf8))
    #expect(manifest.tiles["9f86d0"] == CacheManifest.Tile(source: "/Users/capon/Documents/MacMiller/swimming.jpg", mtime: 1760800000.25))
    let again = try JSONDecoder().decode(CacheManifest.self, from: JSONEncoder().encode(manifest))
    #expect(again == manifest)
}
