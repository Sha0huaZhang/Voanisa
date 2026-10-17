import XCTest
@testable import Voanisa

final class SongSearchTests: XCTestCase {
    private func track(
        title: String,
        artist: String = "",
        album: String = "",
        albumArtist: String = ""
    ) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: artist,
            album: album,
            duration: 1,
            fileName: "\(title).mp3",
            coverFileName: nil,
            format: "MP3",
            contentHash: title,
            dateAdded: Date(timeIntervalSince1970: 0),
            albumArtist: albumArtist
        )
    }

    private var library: [Track] {
        [
            track(title: "Blue Bird", artist: "Ikimono", album: "Naruto"),
            track(title: "夜曲", artist: "周杰伦", album: "十一月的萧邦"),
            track(title: "The Rain", artist: "Yiruma", album: "The Best")
        ]
    }

    func testEmptyQueryReturnsEverything() {
        XCTAssertEqual(SongSearch.filter(library, query: "").count, 3)
        XCTAssertEqual(SongSearch.filter(library, query: "   ").count, 3)
    }

    func testMatchesTitleCaseInsensitively() {
        let result = SongSearch.filter(library, query: "blue")
        XCTAssertEqual(result.map(\.title), ["Blue Bird"])
    }

    func testMatchesArtist() {
        let result = SongSearch.filter(library, query: "周杰伦")
        XCTAssertEqual(result.map(\.title), ["夜曲"])
    }

    func testMatchesAlbum() {
        let result = SongSearch.filter(library, query: "naruto")
        XCTAssertEqual(result.map(\.title), ["Blue Bird"])
    }

    func testMatchesAlbumArtist() {
        let list = [track(title: "Compilation", albumArtist: "Various Artists")]
        let result = SongSearch.filter(list, query: "various")
        XCTAssertEqual(result.map(\.title), ["Compilation"])
    }

    func testTrimsWhitespace() {
        let result = SongSearch.filter(library, query: "  yiruma ")
        XCTAssertEqual(result.map(\.title), ["The Rain"])
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(SongSearch.filter(library, query: "does-not-exist").isEmpty)
    }

    func testActiveQueryDetection() {
        XCTAssertFalse(SongSearch.isActive(""))
        XCTAssertFalse(SongSearch.isActive("  \n"))
        XCTAssertTrue(SongSearch.isActive("a"))
    }
}
