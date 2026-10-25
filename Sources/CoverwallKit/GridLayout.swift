import CoreGraphics

/// Whole tiles filling the screen edge to edge: `width / columns × height / rows`, so nothing is cut at
/// the border; each cover is aspect-filled into its tile (PLAN.md §4.2). Tile `i` is `slots[i]`, row-major.
public struct GridLayout: Sendable {
    public let columns: Int
    public let rows: Int
    public let tileSize: CGSize
    public let slots: [Slot]

    /// Upper bound for the CLI's computed `tileMaxPixels` default.
    public static let maxTilePixels = 2048

    /// CLI default for `tileMaxPixels`: on-screen tile pixels on the sharpest display, ≤ 2048.
    /// With heroes the cache holds hero-size tiles, so they stay sharp.
    public static func defaultTileMax(columns: Int, rows: Int?, heroes: Int = 0, displays: [(points: CGSize, scale: CGFloat)]) -> Int {
        displays.map { GridLayout(screen: $0.points, columns: columns, rows: rows)
            .pixelSize(scale: $0.scale, tileMax: maxTilePixels, span: heroes > 0 ? 2 : 1) }
            .max() ?? 1024
    }

    /// `rows: nil` derives rows from the screen (`--columns` only) so tiles stay nearly square.
    /// Preview clamps to at most 4x3. `heroes` 2×2 tiles are placed where they fit, positions from `seed`.
    public init(screen: CGSize, columns: Int, rows: Int?, preview: Bool = false, heroes: Int = 0, seed: UInt64 = 0) {
        let columns = preview ? min(columns, 4) : columns
        // Zero-frame ghost instances exist (SPIKE_NOTES.md); never divide by a zero width.
        let fitted = rows ?? (screen.width > 0 ? Int((screen.height * CGFloat(columns) / screen.width).rounded()) : 1)
        self.columns = columns
        self.rows = max(1, min(fitted, preview ? 3 : 16))
        tileSize = CGSize(width: screen.width / CGFloat(columns), height: screen.height / CGFloat(self.rows))
        slots = Slot.layout(columns: columns, rows: self.rows, heroes: heroes, seed: seed)
    }

    public func frame(ofTile index: Int) -> CGRect {
        let slot = slots[index], span = CGFloat(slot.span)
        return CGRect(x: CGFloat(slot.column) * tileSize.width, y: CGFloat(slot.row) * tileSize.height,
                      width: tileSize.width * span, height: tileSize.height * span)
    }

    /// Decode size in pixels: the tile's long side on screen (aspect fill), capped by `tileMaxPixels`.
    /// `square`: the cover is drawn as a square of the tile's short side (uncropped sources, `SourcePolicy.coverFrame`).
    public func pixelSize(scale: CGFloat, tileMax: Int, span: Int = 1, square: Bool = false) -> Int {
        let side = square ? min(tileSize.width, tileSize.height) : max(tileSize.width, tileSize.height)
        return min(Int((side * CGFloat(span) * scale).rounded(.up)), tileMax)
    }
}

/// One tile: `span` × `span` grid cells from (`column`, `row`). Heroes have span 2.
public struct Slot: Equatable, Sendable {
    public let column: Int
    public let row: Int
    public let span: Int

    public init(column: Int, row: Int, span: Int) {
        self.column = column
        self.row = row
        self.span = span
    }

    /// Up to `heroes` 2×2 tiles at seeded positions, never touching (not even at corners); 1×1 tiles fill
    /// the rest. Sorted row-major by top-left cell.
    public static func layout(columns: Int, rows: Int, heroes: Int, seed: UInt64) -> [Slot] {
        var rng = SplitMix64(state: seed)
        let origins = (0..<max(0, rows - 1)).flatMap { row in (0..<max(0, columns - 1)).map { (column: $0, row: row) } }
        // Random greedy placement can box itself in; keep the best of a few shuffles.
        var best: (heroes: [Slot], taken: Set<Int>) = ([], [])  // taken = cells covered by a hero
        for _ in 0..<16 where best.heroes.count < heroes {
            var attempt: (heroes: [Slot], taken: Set<Int>) = ([], [])
            for origin in origins.shuffled(using: &rng) where attempt.heroes.count < heroes {
                let around = (origin.row - 1...origin.row + 2).flatMap { row in
                    (origin.column - 1...origin.column + 2).filter { (0..<columns).contains($0) }.map { row * columns + $0 }
                }
                guard attempt.taken.isDisjoint(with: around) else { continue }
                attempt.taken.formUnion([0, 1, columns, columns + 1].map { origin.row * columns + origin.column + $0 })
                attempt.heroes.append(Slot(column: origin.column, row: origin.row, span: 2))
            }
            if attempt.heroes.count > best.heroes.count { best = attempt }
        }
        let singles = (0..<columns * rows).filter { !best.taken.contains($0) }.map { Slot(column: $0 % columns, row: $0 / columns, span: 1) }
        return (best.heroes + singles).sorted { ($0.row, $0.column) < ($1.row, $1.column) }
    }

    /// For each tile, the tiles sharing an edge with it.
    public static func neighbours(_ slots: [Slot]) -> [[Int]] {
        func overlap(_ a: Int, _ aSpan: Int, _ b: Int, _ bSpan: Int) -> Bool { a < b + bSpan && b < a + aSpan }
        func touch(_ a: Int, _ aSpan: Int, _ b: Int, _ bSpan: Int) -> Bool { a + aSpan == b || b + bSpan == a }
        return slots.map { a in
            slots.indices.filter { let b = slots[$0]
                return (overlap(a.column, a.span, b.column, b.span) && touch(a.row, a.span, b.row, b.span))
                    || (overlap(a.row, a.span, b.row, b.span) && touch(a.column, a.span, b.column, b.span))
            }
        }
    }
}
