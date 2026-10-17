import XCTest
@testable import Voanisa

final class SongReorderTests: XCTestCase {
    private func songs(_ titles: [String]) -> [Track] {
        titles.map { title in
            Track(
                id: UUID(),
                title: title,
                artist: "",
                album: "",
                duration: 1,
                fileName: "\(title).mp3",
                coverFileName: nil,
                format: "MP3",
                contentHash: title,
                dateAdded: Date(timeIntervalSince1970: 0)
            )
        }
    }

    func testMovesFirstSongToTheEnd() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(list[0].id, toSlot: 3, in: list)
        XCTAssertEqual(result.map(\.title), ["B", "C", "A"])
    }

    func testMovesLastSongToTheFront() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(list[2].id, toSlot: 0, in: list)
        XCTAssertEqual(result.map(\.title), ["C", "A", "B"])
    }

    func testMoveToGapAboveItselfIsANoOp() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(list[1].id, toSlot: 1, in: list)
        XCTAssertEqual(result.map(\.title), ["A", "B", "C"])
    }

    func testMoveToGapBelowItselfIsANoOp() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(list[1].id, toSlot: 2, in: list)
        XCTAssertEqual(result.map(\.title), ["A", "B", "C"])
    }

    func testClampsOutOfRangeSlots() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(list[1].id, toSlot: 99, in: list)
        XCTAssertEqual(result.map(\.title), ["A", "C", "B"])
    }

    func testUnknownIDLeavesTheListUnchanged() {
        let list = songs(["A", "B", "C"])
        let result = SongReorder.moving(UUID(), toSlot: 0, in: list)
        XCTAssertEqual(result.map(\.title), ["A", "B", "C"])
    }

    func testEmptyListStaysEmpty() {
        let result = SongReorder.moving(UUID(), toSlot: 0, in: [])
        XCTAssertTrue(result.isEmpty)
    }
}
