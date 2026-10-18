import CoreGraphics
import Testing
import CoverwallKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

@Test func coversWideScreenAndCropsRowsEvenly() {
    let layout = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: 5)
    #expect(layout.columns == 7 && layout.rows == 5)
    #expect(near(layout.tileSize, 274.29))
    let first = layout.frame(ofTile: 0)
    #expect(near(first.minX, 0) && near(first.minY, -145.71))
    let last = layout.frame(ofTile: 34)
    #expect(near(last.maxX, 1920) && near(last.maxY, 1225.71))
}

@Test(arguments: [
    // width, height, columns, rows → tile, origin x, origin y
    (2560.0, 1600.0, 4, 3, 640.0, 0.0, -160.0),   // 16:10, rows cropped
    (3440.0, 1440.0, 8, 3, 480.0, -200.0, 0.0),   // ultrawide, columns cropped
    (1920.0, 1080.0, 1, 1, 1920.0, 0.0, -420.0),  // 1x1, one big centered cover
])
func coversOtherAspectRatios(w: CGFloat, h: CGFloat, c: Int, r: Int, tile: CGFloat, x: CGFloat, y: CGFloat) {
    let layout = GridLayout(screen: CGSize(width: w, height: h), columns: c, rows: r)
    #expect(near(layout.tileSize, tile))
    let first = layout.frame(ofTile: 0)
    #expect(near(first.minX, x) && near(first.minY, y))
}

@Test func columnsOnlyDerivesRowsFromScreen() {
    let layout = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: nil)
    #expect(layout.rows == 4)  // ceil(1080 / 274.29)
    #expect(near(layout.tileSize, 274.29))
    #expect(near(layout.frame(ofTile: 0).minY, -8.57))
}

@Test func columnsOnlyKeepsRowsWithinLimit() {
    let layout = GridLayout(screen: CGSize(width: 1080, height: 1920), columns: 16, rows: nil)
    #expect(layout.rows == 16)
}

@Test func previewClampsToFourByThree() {
    let layout = GridLayout(screen: CGSize(width: 320, height: 180), columns: 7, rows: 5, preview: true)
    #expect(layout.columns == 4 && layout.rows == 3)
    #expect(near(layout.tileSize, 80))
    #expect(near(layout.frame(ofTile: 0).minY, -30))
}

@Test func zeroFrameGhostInstanceDoesNotCrash() {
    let layout = GridLayout(screen: .zero, columns: 7, rows: nil)
    #expect(layout.rows == 1)
}

@Test func pixelSizeIsTileTimesScaleCappedByTileMax() {
    let grid = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: 5)
    #expect(grid.pixelSize(scale: 2, tileMax: 1024) == 549)  // ceil(274.29 × 2)
    #expect(grid.pixelSize(scale: 2, tileMax: 400) == 400)
}

@Test func cliDefaultTileMaxNeverExceeds2048() {
    let single = GridLayout(screen: CGSize(width: 2560, height: 1440), columns: 1, rows: 1)
    #expect(single.pixelSize(scale: 2, tileMax: GridLayout.maxTilePixels) == 2048)
}

@Test func defaultTileMaxFitsTheSharpestDisplay() {
    let displays = [(points: CGSize(width: 1920, height: 1080), scale: CGFloat(1)),
                    (points: CGSize(width: 2560, height: 1440), scale: CGFloat(2))]
    #expect(GridLayout.defaultTileMax(columns: 7, rows: 5, displays: displays) == 732)  // ceil(2560 / 7 × 2)
    #expect(GridLayout.defaultTileMax(columns: 1, rows: 1, displays: displays) == 2048)
    #expect(GridLayout.defaultTileMax(columns: 7, rows: 5, displays: []) == 1024)       // headless
}
