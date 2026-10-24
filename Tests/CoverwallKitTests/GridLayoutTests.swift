import CoreGraphics
import Testing
import CoverwallKit

private func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.01 }

private func near(_ a: CGSize, _ w: CGFloat, _ h: CGFloat) -> Bool { near(a.width, w) && near(a.height, h) }

@Test func fillsTheScreenEdgeToEdgeWithWholeTiles() {
    let layout = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: 5)
    #expect(layout.columns == 7 && layout.rows == 5)
    #expect(near(layout.tileSize, 274.29, 216))
    #expect(layout.frame(ofTile: 0).origin == .zero)
    let last = layout.frame(ofTile: 34)
    #expect(near(last.maxX, 1920) && near(last.maxY, 1080))
}

@Test(arguments: [
    // width, height, columns, rows → tile width, height
    (2560.0, 1600.0, 4, 3, 640.0, 533.33),   // 16:10
    (3440.0, 1440.0, 8, 3, 430.0, 480.0),    // ultrawide
    (1920.0, 1080.0, 1, 1, 1920.0, 1080.0),  // 1x1, one cover fills the screen
])
func fillsOtherAspectRatios(w: CGFloat, h: CGFloat, c: Int, r: Int, tileW: CGFloat, tileH: CGFloat) {
    let layout = GridLayout(screen: CGSize(width: w, height: h), columns: c, rows: r)
    #expect(near(layout.tileSize, tileW, tileH))
    #expect(layout.frame(ofTile: 0).origin == .zero)
}

@Test func columnsOnlyRoundsRowsSoTilesStayNearlySquare() {
    let layout = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: nil)
    #expect(layout.rows == 4)  // 1080 / 274.29 = 3.94
    #expect(near(layout.tileSize, 274.29, 270))
    #expect(near(layout.frame(ofTile: 27).maxY, 1080))
}

@Test func columnsOnlyKeepsRowsWithinLimit() {
    let layout = GridLayout(screen: CGSize(width: 1080, height: 1920), columns: 16, rows: nil)
    #expect(layout.rows == 16)
}

@Test func previewClampsToFourByThree() {
    let layout = GridLayout(screen: CGSize(width: 320, height: 180), columns: 7, rows: 5, preview: true)
    #expect(layout.columns == 4 && layout.rows == 3)
    #expect(near(layout.tileSize, 80, 60))
}

@Test func zeroFrameGhostInstanceDoesNotCrash() {
    let layout = GridLayout(screen: .zero, columns: 7, rows: nil)
    #expect(layout.rows == 1)
}

@Test func pixelSizeIsTheTilesLongSideTimesScaleCappedByTileMax() {
    let grid = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 7, rows: 5)
    #expect(grid.pixelSize(scale: 2, tileMax: 1024) == 549)  // ceil(274.29 × 2)
    #expect(grid.pixelSize(scale: 2, tileMax: 400) == 400)
    let tall = GridLayout(screen: CGSize(width: 1920, height: 1080), columns: 8, rows: 2)  // 240 × 540
    #expect(tall.pixelSize(scale: 1, tileMax: 1024) == 540)
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

// MARK: - Hero tiles

private let screen = CGSize(width: 1920, height: 1080)

private func cells(_ slot: Slot, columns: Int) -> [Int] {
    (slot.row..<slot.row + slot.span).flatMap { row in (slot.column..<slot.column + slot.span).map { row * columns + $0 } }
}

@Test func heroesAreTwoByTwoAndAllTilesCoverEveryCellOnce() throws {
    let layout = GridLayout(screen: screen, columns: 7, rows: 5, heroes: 3, seed: 1)
    #expect(layout.slots.filter { $0.span == 2 }.count == 3)
    #expect(layout.slots.flatMap { cells($0, columns: 7) }.sorted() == Array(0..<35))
    let hero = try #require(layout.slots.firstIndex { $0.span == 2 })
    #expect(near(layout.frame(ofTile: hero).size, 548.57, 432))
}

@Test func heroesNeverTouchEachOther() {
    for seed in UInt64(0)..<50 {
        let slots = GridLayout(screen: screen, columns: 7, rows: 5, heroes: 4, seed: seed).slots
        let neighbours = Slot.neighbours(slots)
        for hero in slots.indices where slots[hero].span == 2 {
            #expect(neighbours[hero].allSatisfy { slots[$0].span == 1 })
        }
    }
}

@Test func heroesOnlyWhereTheyFitAndTheSameSeedGivesTheSameLayout() {
    #expect(GridLayout(screen: screen, columns: 1, rows: 1, heroes: 3, seed: 0).slots == [Slot(column: 0, row: 0, span: 1)])
    #expect(GridLayout(screen: screen, columns: 3, rows: 2, heroes: 5, seed: 0).slots.filter { $0.span == 2 }.count == 1)
    #expect(GridLayout(screen: screen, columns: 7, rows: 5, heroes: 3, seed: 7).slots
            == GridLayout(screen: screen, columns: 7, rows: 5, heroes: 3, seed: 7).slots)
}

@Test func plainGridTilesAreRowMajorAndNeighboursShareAnEdge() {
    let slots = GridLayout(screen: screen, columns: 3, rows: 2).slots
    #expect(slots.map { cells($0, columns: 3) } == (0..<6).map { [$0] })
    #expect(Slot.neighbours(slots).map { $0.sorted() } == [[1, 3], [0, 2, 4], [1, 5], [0, 4], [1, 3, 5], [2, 4]])
}

@Test func aHeroNeighboursEveryTileAlongItsEdges() throws {
    // 3x2 with one hero: the hero plus one column of two stacked tiles, whichever side it lands.
    let slots = GridLayout(screen: screen, columns: 3, rows: 2, heroes: 1, seed: 3).slots
    let neighbours = Slot.neighbours(slots)
    let hero = try #require(slots.firstIndex { $0.span == 2 })
    for tile in slots.indices { #expect(Set(neighbours[tile]) == Set(slots.indices).subtracting([tile])) }
    #expect(neighbours[hero].count == 2)
}

@Test func heroPixelSizeIsTwiceTheTileCappedByTileMax() {
    let grid = GridLayout(screen: screen, columns: 7, rows: 5)
    #expect(grid.pixelSize(scale: 2, tileMax: 2048, span: 2) == 1098)  // ceil(548.57 × 2)
    #expect(grid.pixelSize(scale: 2, tileMax: 1024, span: 2) == 1024)
}

@Test func defaultTileMaxWithHeroesCachesAtHeroSize() {
    let displays = [(points: CGSize(width: 2560, height: 1440), scale: CGFloat(2))]
    #expect(GridLayout.defaultTileMax(columns: 7, rows: 5, heroes: 3, displays: displays) == 1463)  // ceil(2560 / 7 × 4)
    #expect(GridLayout.defaultTileMax(columns: 7, rows: 5, heroes: 0, displays: displays) == 732)
}

@Test func threeHeroesAlwaysFitOnTheDefaultGrid() {
    for seed in UInt64(0)..<200 {
        #expect(Slot.layout(columns: 7, rows: 5, heroes: 3, seed: seed).filter { $0.span == 2 }.count == 3, "seed \(seed)")
    }
}
