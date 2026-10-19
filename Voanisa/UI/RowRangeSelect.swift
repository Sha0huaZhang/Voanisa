import CoreGraphics

/// Turns a drag inside the picker into a range of rows.
///
/// The pointer is reported in global coordinates, and the rows publish their own
/// global frames; everything here is pure arithmetic so the behaviour can be
/// tested without a window.
enum RowRangeSelect {
    /// The row under the pointer.
    ///
    /// A point inside a row wins. A point between rows takes the closest one, and
    /// a point past either end takes the first or last row, so dragging out of
    /// the list keeps extending the selection instead of stopping. Returns `nil`
    /// when no row has reported a frame yet.
    static func index(atY y: CGFloat, frames: [CGRect?]) -> Int? {
        let known = frames.indices.filter { frames[$0] != nil }
        guard !known.isEmpty else { return nil }

        if let hit = known.first(where: { frames[$0]!.contains(CGPoint(x: frames[$0]!.midX, y: y)) }) {
            return hit
        }
        return known.min { a, b in
            abs(frames[a]!.midY - y) < abs(frames[b]!.midY - y)
        }
    }

    /// Every index between two rows, whichever direction the drag went.
    static func span(_ first: Int, _ second: Int) -> ClosedRange<Int> {
        first <= second ? first...second : second...first
    }
}
