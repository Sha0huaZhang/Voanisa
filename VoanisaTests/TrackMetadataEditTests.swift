import XCTest
@testable import Voanisa

final class TrackMetadataEditTests: XCTestCase {
    func testApplyingTrimsFieldsAndPreservesFileIdentity() {
        let track = makeTrack()
        var edit = TrackMetadataEdit(track: track)
        edit.title = "  New Title  "
        edit.artist = "  Artist "
        edit.album = " Album  "
        edit.albumArtist = "  Album Artist "
        edit.trackNumber = 3
        edit.discNumber = 2

        let updated = edit.applying(to: track)

        XCTAssertEqual(updated.title, "New Title")
        XCTAssertEqual(updated.artist, "Artist")
        XCTAssertEqual(updated.album, "Album")
        XCTAssertEqual(updated.albumArtist, "Album Artist")
        XCTAssertEqual(updated.trackNumber, 3)
        XCTAssertEqual(updated.discNumber, 2)
        XCTAssertEqual(updated.id, track.id)
        XCTAssertEqual(updated.fileName, track.fileName)
        XCTAssertEqual(updated.contentHash, track.contentHash)
        XCTAssertEqual(updated.duration, track.duration)
        XCTAssertEqual(updated.coverFileName, track.coverFileName)
    }

    func testWhitespaceOnlyTitleIsInvalid() {
        var edit = TrackMetadataEdit(track: makeTrack())
        edit.title = "   \n"
        XCTAssertFalse(edit.isValid)

        edit.title = "Title"
        XCTAssertTrue(edit.isValid)
    }

    private func makeTrack() -> Track {
        Track(
            id: UUID(),
            title: "Title",
            artist: "Artist",
            album: "Album",
            duration: 12,
            fileName: "file.mp3",
            coverFileName: "cover.jpg",
            format: "MP3",
            contentHash: "hash",
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }
}
