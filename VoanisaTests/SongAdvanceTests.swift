import XCTest
@testable import Voanisa

final class SongAdvanceTests: XCTestCase {
    func testMovesWithinTheList() {
        XCTAssertEqual(
            SongAdvance.targetIndex(anchorIndex: 1, count: 3, offset: 1, repeatAll: false),
            2
        )
        XCTAssertEqual(
            SongAdvance.targetIndex(anchorIndex: 1, count: 3, offset: -1, repeatAll: false),
            0
        )
    }

    func testWrapsOnlyWhenRepeatAllIsOn() {
        XCTAssertEqual(
            SongAdvance.targetIndex(anchorIndex: 2, count: 3, offset: 1, repeatAll: true),
            0
        )
        XCTAssertEqual(
            SongAdvance.targetIndex(anchorIndex: 0, count: 3, offset: -1, repeatAll: true),
            2
        )
        XCTAssertNil(
            SongAdvance.targetIndex(anchorIndex: 2, count: 3, offset: 1, repeatAll: false)
        )
        XCTAssertNil(
            SongAdvance.targetIndex(anchorIndex: 0, count: 3, offset: -1, repeatAll: false)
        )
    }

    func testUnknownAnchorOrEmptyListDoesNotMove() {
        XCTAssertNil(
            SongAdvance.targetIndex(anchorIndex: nil, count: 3, offset: 1, repeatAll: true)
        )
        XCTAssertNil(
            SongAdvance.targetIndex(anchorIndex: 0, count: 0, offset: 1, repeatAll: true)
        )
    }

    func testPlaybackNavigationMovesWithinTheActiveList() {
        let ids = [UUID(), UUID(), UUID()]

        XCTAssertEqual(
            PlaybackNavigation.targetID(
                currentID: ids[1],
                trackIDs: ids,
                offset: 1,
                repeatAll: false
            ),
            ids[2]
        )
        XCTAssertEqual(
            PlaybackNavigation.targetID(
                currentID: ids[0],
                trackIDs: ids,
                offset: -1,
                repeatAll: true
            ),
            ids[2]
        )
    }

    func testPlaybackNavigationRefusesAnOutsideCurrentTrack() {
        let active = [UUID(), UUID()]
        let outside = UUID()

        XCTAssertNil(
            PlaybackNavigation.targetID(
                currentID: outside,
                trackIDs: active,
                offset: 1,
                repeatAll: true
            )
        )
    }
}
