import Foundation

/// Compact dots stay outside the physical camera. A row wraps only when it
/// would reach the display edge; each session keeps its own visible dot.
struct SessionIndicatorLayout: Equatable {
    static let diameter: CGFloat = 5
    static let pitch: CGFloat = 8
    static let inset: CGFloat = 12

    let count: Int
    let columns: Int
    let rows: Int

    init(count: Int, availableWidth: CGFloat) {
        self.count = max(0, count)
        let capacity = max(1, Int(max(0, availableWidth - 2 * Self.inset) / Self.pitch) + 1)
        rows = max(1, Int(ceil(Double(self.count) / Double(capacity))))
        columns = max(1, Int(ceil(Double(self.count) / Double(rows))))
    }

    var width: CGFloat { 2 * Self.inset + CGFloat(columns - 1) * Self.pitch }

    func center(at index: Int, in size: CGSize) -> CGPoint {
        let column = index % columns
        let row = index / columns
        return CGPoint(x: size.width - width + Self.inset + CGFloat(column) * Self.pitch,
                       y: size.height / 2 + (CGFloat(row) - CGFloat(rows - 1) / 2) * Self.pitch)
    }
}
