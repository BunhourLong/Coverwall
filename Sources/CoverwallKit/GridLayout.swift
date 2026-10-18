import CoreGraphics

/// Whole tiles filling the screen edge to edge: `width / columns × height / rows`, so nothing is cut at
/// the border; each cover is aspect-filled into its tile (PLAN.md §4.2). Tile `i` sits at column
/// `i % columns`, row `i / columns`.
public struct GridLayout: Sendable {
    public let columns: Int
    public let rows: Int
    public let tileSize: CGSize

    /// Upper bound for the CLI's computed `tileMaxPixels` default.
    public static let maxTilePixels = 2048

    /// CLI default for `tileMaxPixels`: on-screen tile pixels on the sharpest display, ≤ 2048.
    public static func defaultTileMax(columns: Int, rows: Int?, displays: [(points: CGSize, scale: CGFloat)]) -> Int {
        displays.map { GridLayout(screen: $0.points, columns: columns, rows: rows).pixelSize(scale: $0.scale, tileMax: maxTilePixels) }
            .max() ?? 1024
    }

    /// `rows: nil` derives rows from the screen (`--columns` only) so tiles stay nearly square.
    /// Preview clamps to at most 4x3.
    public init(screen: CGSize, columns: Int, rows: Int?, preview: Bool = false) {
        let columns = preview ? min(columns, 4) : columns
        // Zero-frame ghost instances exist (SPIKE_NOTES.md); never divide by a zero width.
        let fitted = rows ?? (screen.width > 0 ? Int((screen.height * CGFloat(columns) / screen.width).rounded()) : 1)
        self.columns = columns
        self.rows = max(1, min(fitted, preview ? 3 : 16))
        tileSize = CGSize(width: screen.width / CGFloat(columns), height: screen.height / CGFloat(self.rows))
    }

    public func frame(ofTile index: Int) -> CGRect {
        CGRect(origin: CGPoint(x: CGFloat(index % columns) * tileSize.width, y: CGFloat(index / columns) * tileSize.height),
               size: tileSize)
    }

    /// Decode size in pixels: the tile's long side on screen (aspect fill), capped by `tileMaxPixels`.
    public func pixelSize(scale: CGFloat, tileMax: Int) -> Int {
        min(Int((max(tileSize.width, tileSize.height) * scale).rounded(.up)), tileMax)
    }
}
