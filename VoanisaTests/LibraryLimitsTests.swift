import XCTest
@testable import Voanisa

/// The stress test that motivated these limits pasted ~40 000 characters into a
/// playlist name; the sidebar then laid that string out on the main thread and
/// the app stalled. These tests pin the cut-off so it cannot regress.
final class LibraryLimitsTests: XCTestCase {
    func testCutsAPathologicallyLongName() {
        let input = String(repeating: "A", count: 40_000)
        let result = LibraryLimits.normalized(input, limit: LibraryLimits.playlistName)

        XCTAssertEqual(result.count, LibraryLimits.playlistName)
        XCTAssertEqual(result, String(repeating: "A", count: LibraryLimits.playlistName))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(
            LibraryLimits.normalized("  Playlist\n ", limit: 100),
            "Playlist"
        )
    }

    func testLeavesShortNamesAlone() {
        XCTAssertEqual(LibraryLimits.normalized("Road Trip", limit: 100), "Road Trip")
    }

    func testDoesNotSplitGraphemeClusters() {
        let result = LibraryLimits.normalized("👍👍👍", limit: 2)

        XCTAssertEqual(result, "👍👍")
        XCTAssertEqual(result.count, 2)
    }

    func testBlankInputBecomesEmpty() {
        XCTAssertEqual(LibraryLimits.normalized("   \n", limit: 100), "")
    }

    func testNameAtTheLimitIsUnchanged() {
        let input = String(repeating: "x", count: 100)
        XCTAssertEqual(LibraryLimits.normalized(input, limit: 100), input)
    }
}
