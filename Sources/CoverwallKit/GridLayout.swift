import CoreGraphics

/// Square tiles scaled to cover the screen, centered, overflow cropped (PLAN.md §4.2).
/// Tile `i` sits at column `i % columns`, row `i / columns`.
public struct GridLayout: Sendable {
    public let columns: Int
    public let rows: Int
    public let tileSize: CGFloat
    let origin: CGPoint

    /// Upper bound for the CLI's computed `tileMaxPixels` default.
    public static let maxTilePixels = 2048

    /// CLI default for `tileMaxPixels`: on-screen tile pixels on the sharpest display, ≤ 2048.
    public static func defaultTileMax(columns: Int, rows: Int?, displays: [(points: CGSize, scale: CGFloat)]) -> Int {
        displays.map { GridLayout(screen: $0.points, columns: columns, rows: rows).pixelSize(scale: $0.scale, tileMax: maxTilePixels) }
            .max() ?? 1024
    }

    /// `rows: nil` derives rows from the screen (`--columns` only). Preview clamps to at most 4x3.
    public init(screen: CGSize, columns: Int, rows: Int?, preview: Bool = false) {
        let columns = preview ? min(columns, 4) : columns
        // Zero-frame ghost instances exist (SPIKE_NOTES.md); never divide by a zero width.
        let fitted = rows ?? (screen.width > 0 ? Int((screen.height * CGFloat(columns) / screen.width).rounded(.up)) : 1)
        self.columns = columns
        self.rows = max(1, min(fitted, preview ? 3 : 16))
        tileSize = max(screen.width / CGFloat(columns), screen.height / CGFloat(self.rows))
        origin = CGPoint(x: (screen.width - tileSize * CGFloat(columns)) / 2,
                         y: (screen.height - tileSize * CGFloat(self.rows)) / 2)
    }

    public func frame(ofTile index: Int) -> CGRect {
        CGRect(x: origin.x + CGFloat(index % columns) * tileSize,
               y: origin.y + CGFloat(index / columns) * tileSize,
               width: tileSize, height: tileSize)
    }

    /// Decode size in pixels: on-screen tile pixels, capped by the profile's `tileMaxPixels`.
    public func pixelSize(scale: CGFloat, tileMax: Int) -> Int {
        min(Int((tileSize * scale).rounded(.up)), tileMax)
    }
}
