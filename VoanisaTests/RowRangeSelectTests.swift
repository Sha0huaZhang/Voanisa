import XCTest
@testable import Voanisa

final class RowRangeSelectTests: XCTestCase {
    private func frames(_ count: Int, height: CGFloat = 40, startY: CGFloat = 0) -> [CGRect?] {
        (0..<count).map { index in
            CGRect(x: 0, y: startY + CGFloat(index) * height, width: 300, height: height)
        }
    }

    func testFindsTheRowUnderThePointer() {
        let rows = frames(3)
        XCTAssertEqual(RowRangeSelect.index(atY: 10, frames: rows), 0)
        XCTAssertEqual(RowRangeSelect.index(atY: 50, frames: rows), 1)
        XCTAssertEqual(RowRangeSelect.index(atY: 110, frames: rows), 2)
    }

    func testBetweenRowsTakesTheClosestOne() {
        let rows = frames(3)
        // 38 is inside row 0; 42 is inside row 1 — the boundary sits at 40.
        XCTAssertEqual(RowRangeSelect.index(atY: 39, frames: rows), 0)
        XCTAssertEqual(RowRangeSelect.index(atY: 41, frames: rows), 1)
    }

    func testPastEitherEndClampsToFirstOrLast() {
        let rows = frames(3)
        XCTAssertEqual(RowRangeSelect.index(atY: -500, frames: rows), 0)
        XCTAssertEqual(RowRangeSelect.index(atY: 5_000, frames: rows), 2)
    }

    func testIgnoresRowsWithoutAFrame() {
        var rows: [CGRect?] = frames(3)
        rows[1] = nil
        // Dropping into the middle still resolves to a neighbour rather than nil.
        XCTAssertEqual(RowRangeSelect.index(atY: 46, frames: rows), 0)
        XCTAssertNil(RowRangeSelect.index(atY: 46, frames: [nil, nil]))
    }

    func testSpanWorksInBothDirections() {
        XCTAssertEqual(RowRangeSelect.span(1, 3), 1...3)
        XCTAssertEqual(RowRangeSelect.span(3, 1), 1...3)
        XCTAssertEqual(RowRangeSelect.span(2, 2), 2...2)
    }
}
