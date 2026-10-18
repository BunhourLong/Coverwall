import Testing
import CoverwallKit

private func pool(_ n: Int) -> [String] { (0..<n).map { "img\($0)" } }

@Test func fillShowsDistinctPoolImagesWhenPoolIsLargeEnough() {
    var bag = ShuffleBag(pool: pool(100), columns: 7, rows: 5, seed: 1)
    let shown = bag.fill()
    #expect(shown.count == 35)
    #expect(Set(shown).count == 35)
    #expect(Set(shown).isSubset(of: pool(100)))
}

@Test func sameSeedSameSequenceDifferentSeedDifferent() {
    var a = ShuffleBag(pool: pool(100), columns: 7, rows: 5, seed: 42)
    var b = ShuffleBag(pool: pool(100), columns: 7, rows: 5, seed: 42)
    var c = ShuffleBag(pool: pool(100), columns: 7, rows: 5, seed: 43)
    let first = a.fill()
    #expect(first == b.fill())
    #expect(first != c.fill())
}

@Test func ticksNeverPutADuplicateOnScreen() {
    var bag = ShuffleBag(pool: pool(40), columns: 7, rows: 5, seed: 7)
    _ = bag.fill()
    for _ in 0..<1000 {
        let swaps = bag.tick(swaps: 3, busy: [])
        #expect(!swaps.isEmpty)
        #expect(Set(bag.visible).count == 35)
    }
}

@Test func everyImageShowsOncePerBagCycle() {
    var bag = ShuffleBag(pool: pool(10), columns: 1, rows: 1, seed: 3)
    var seen = Set(bag.fill())
    for _ in 0..<9 { seen.formUnion(bag.tick(swaps: 1, busy: []).map(\.image)) }
    #expect(seen == Set(pool(10)))
}

private func adjacent(_ a: Int, _ b: Int, columns: Int) -> Bool {
    let (ar, ac, br, bc) = (a / columns, a % columns, b / columns, b % columns)
    return abs(ar - br) + abs(ac - bc) == 1
}

@Test func ticksSkipBusyRecentAndAdjacentTiles() {
    var bag = ShuffleBag(pool: pool(100), columns: 7, rows: 5, seed: 9)
    _ = bag.fill()
    var recent: [Int] = []
    for n in 0..<500 {
        let busy: Set<Int> = [n % 35, (n * 11) % 35]
        let tiles = bag.tick(swaps: 3, busy: busy).map(\.tile)
        #expect(!tiles.isEmpty)
        #expect(tiles.allSatisfy { !busy.contains($0) && !recent.contains($0) })
        for a in tiles { for b in tiles where a < b { #expect(!adjacent(a, b, columns: 7)) } }
        recent = Array((recent + tiles).suffix(7))  // last C positions
    }
}

private func hasIdenticalNeighbours(_ shown: [String], columns: Int) -> Bool {
    shown.indices.contains { a in shown.indices.contains { b in a < b && adjacent(a, b, columns: columns) && shown[a] == shown[b] } }
}

@Test func smallPoolRepeatsImagesButNeverSideBySide() {
    var bag = ShuffleBag(pool: pool(6), columns: 4, rows: 3, seed: 5)
    let shown = bag.fill()
    #expect(shown.count == 12)
    #expect(!hasIdenticalNeighbours(shown, columns: 4))
    for _ in 0..<500 {
        #expect(!bag.tick(swaps: 2, busy: []).isEmpty)
        #expect(!hasIdenticalNeighbours(bag.visible, columns: 4))
    }
}

@Test func singleImageFillsEveryTileAndNeverHangs() {
    var bag = ShuffleBag(pool: pool(1), columns: 4, rows: 3, seed: 5)
    #expect(bag.fill() == Array(repeating: "img0", count: 12))
    #expect(bag.tick(swaps: 2, busy: []).isEmpty)  // nothing different to show
}

@Test func emptyPoolShowsNothing() {
    var bag = ShuffleBag(pool: [], columns: 7, rows: 5, seed: 5)
    #expect(bag.fill().isEmpty)
    #expect(bag.tick(swaps: 1, busy: []).isEmpty)
}
