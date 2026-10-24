/// Which image goes on which tile (PLAN.md §4.3). Images are opaque ids (cache file names).
/// Tile indices match `GridLayout.frame(ofTile:)` / `GridLayout.slots`.
public struct ShuffleBag: Sendable {
    public private(set) var visible: [String] = []
    private let pool: [String]
    private let columns: Int
    private let tiles: Int
    private let neighbourLists: [[Int]]
    private var bag: [String] = []
    private var recent: [Int] = []
    private var rng: SplitMix64

    public init(pool: [String], columns: Int, rows: Int, seed: UInt64) {
        self.init(pool: pool, slots: Slot.layout(columns: columns, rows: rows, heroes: 0, seed: 0), seed: seed)
    }

    public init(pool: [String], slots: [Slot], seed: UInt64) {
        self.pool = pool
        columns = slots.map { $0.column + $0.span }.max() ?? 0
        tiles = slots.count
        neighbourLists = Slot.neighbours(slots)
        rng = SplitMix64(state: seed)
    }

    /// Initial grid, one image per tile.
    public mutating func fill() -> [String] {
        visible = []
        for tile in 0..<tiles {
            guard let image = draw(forbidden: forbidden(at: tile)) ?? draw(forbidden: []) else { break }
            visible.append(image)
        }
        return visible
    }

    /// Replaces up to `swaps` tiles. Skips `busy` tiles (mid-transition), the last ~`columns`
    /// swapped tiles, and neighbours of tiles already picked this tick.
    public mutating func tick(swaps: Int, busy: Set<Int>) -> [Swap] {
        var result: [Swap] = []
        let skip = busy.union(recent)
        for tile in (0..<visible.count).filter({ !skip.contains($0) }).shuffled(using: &rng) {
            guard result.count < swaps else { break }
            guard !result.contains(where: { neighbours(of: tile).contains($0.tile) }),
                  let image = draw(forbidden: forbidden(at: tile)) ?? (smallPool ? draw(forbidden: [visible[tile]]) : nil)
            else { continue }
            visible[tile] = image
            result.append(Swap(tile: tile, image: image))
        }
        // Remember fewer tiles on tiny grids, or 1x1 could never swap again.
        recent = Array((recent + result.map(\.tile)).suffix(max(0, min(columns, tiles - swaps))))
        return result
    }

    private var smallPool: Bool { pool.count < tiles }

    /// Large pool: nothing already on screen. Small pool (duplicates allowed): not the tile's
    /// current image and, best effort, not a neighbour's.
    private func forbidden(at tile: Int) -> Set<String> {
        guard smallPool else { return Set(visible) }
        return Set((neighbours(of: tile) + [tile]).filter { $0 < visible.count }.map { visible[$0] })
    }

    private func neighbours(of tile: Int) -> [Int] { neighbourLists[tile] }

    /// Next bag image that isn't forbidden; refills the bag once if it runs dry.
    private mutating func draw(forbidden: Set<String>) -> String? {
        for attempt in 0..<2 {
            if let i = bag.lastIndex(where: { !forbidden.contains($0) }) { return bag.remove(at: i) }
            if attempt == 0 { bag = pool.shuffled(using: &rng) }
        }
        return nil
    }
}

public struct Swap: Equatable, Sendable {
    public let tile: Int
    public let image: String
}

/// Seedable RNG (stdlib has none). https://prng.di.unimi.it/splitmix64.c
struct SplitMix64: RandomNumberGenerator, Sendable {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
