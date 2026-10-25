import CoreGraphics
import Testing
import CoverwallKit

private let spotify = SourcePolicy(crop: .none, attribution: .spotify, cacheTTL: 3600, mixable: false)

@Test func spotifyLogoSitsCenteredBelowTheGridWithItsClearSpace() {
    // Full logo 3432×940: icon as tall as the logo, so the clear space (½ icon height) is half the logo height.
    #expect(SourcePolicy.Attribution.spotify.bandHeight == 48)
    let logo = SourcePolicy.Attribution.spotify.logoFrame(width: 1000, aspect: 3432.0 / 940)
    #expect(logo.height == 24 && logo.minY == 12 && logo.maxY == 36)                 // 12 pt clear above and below
    #expect(logo.width >= 70)                                                         // minimum full-logo size
    #expect(abs(logo.midX - 500) < 0.001)

    #expect(SourcePolicy.Attribution.none.bandHeight == 0)
}

@Test func logoColourFollowsTheBackground() {
    #expect(SourcePolicy.Attribution.spotify.logoName(background: "#000000") == "Spotify_Full_Logo_RGB_White")
    #expect(SourcePolicy.Attribution.spotify.logoName(background: "#191414") == "Spotify_Full_Logo_RGB_White")
    #expect(SourcePolicy.Attribution.spotify.logoName(background: "#FFFFFF") == "Spotify_Full_Logo_RGB_Black")
    #expect(SourcePolicy.Attribution.spotify.logoName(background: "#F0E68C") == "Spotify_Full_Logo_RGB_Black")
    #expect(SourcePolicy.Attribution.none.logoName(background: "#000000") == nil)
}

@Test func uncroppedCoversGetARoundedSquareCroppedOnesFillTheTile() {
    let tile = CGRect(x: 10, y: 20, width: 300, height: 200)
    #expect(spotify.coverFrame(in: tile) == CGRect(x: 60, y: 20, width: 200, height: 200))
    #expect(spotify.cornerRadius == 8)
    #expect(SourcePolicy.localFolder.coverFrame(in: tile) == tile)
    #expect(SourcePolicy.localFolder.cornerRadius == 0)
}

@Test func attributedSourcesFadeBecauseAFlipDistortsArtworkAndCrossesTheLogo() {
    #expect(spotify.transition(preferred: .flip) == .fade)
    #expect(SourcePolicy.localFolder.transition(preferred: .flip) == .flip)
    #expect(SourcePolicy.localFolder.transition(preferred: .fade) == .fade)
}

@Test func tooSmallForTheLogoAndItsClearSpaceMeansNoCovers() {
    let aspect = 3432.0 / 940  // logo ≈ 87.6 pt + 12 pt clear space each side
    #expect(SourcePolicy.Attribution.spotify.fits(width: 1280, height: 720, aspect: aspect))
    #expect(!SourcePolicy.Attribution.spotify.fits(width: 100, height: 720, aspect: aspect))
    #expect(!SourcePolicy.Attribution.spotify.fits(width: 1280, height: 48, aspect: aspect))
    #expect(SourcePolicy.Attribution.none.fits(width: 59, height: 16, aspect: aspect))
}

@Test func logoSnapsToThePixelGridSoItStaysSharp() {
    for scale: CGFloat in [1, 2] {
        let logo = SourcePolicy.Attribution.spotify.logoFrame(width: 1279, aspect: 3432.0 / 940, scale: scale)
        for value in [logo.minX, logo.minY, logo.width, logo.height] { #expect((value * scale).rounded() == value * scale, "\(value) @\(scale)x") }
        #expect(logo.width >= 70 && logo.height == 24)
    }
}

@Test func squareCoversDecodeAtTheirDrawnSizeNotTheTilesLongSide() {
    let grid = GridLayout(screen: CGSize(width: 1280, height: 672), columns: 4, rows: 3)  // tiles 320 × 224
    #expect(grid.pixelSize(scale: 2, tileMax: 2048) == 640)
    #expect(grid.pixelSize(scale: 2, tileMax: 2048, square: true) == 448)
}
