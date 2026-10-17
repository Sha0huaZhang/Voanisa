import XCTest
@testable import Voanisa

final class TrackTests: XCTestCase {
    func testDecodesPrototypeSnapshotWithoutNewMetadata() throws {
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "title": "Old",
          "artist": "Artist",
          "album": "Album",
          "duration": 12.5,
          "fileName": "old.mp3",
          "coverFileName": null,
          "format": "MP3",
          "contentHash": "hash-old",
          "dateAdded": 0
        }
        """

        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))

        XCTAssertEqual(track.title, "Old")
        XCTAssertEqual(track.artist, "Artist")
        XCTAssertEqual(track.albumArtist, "")
        XCTAssertNil(track.trackNumber)
        XCTAssertNil(track.discNumber)
        XCTAssertEqual(track.source, "local")
        XCTAssertNil(track.musicPersistentID)
    }

    func testRoundTripsFullMetadata() throws {
        let track = Track(
            id: UUID(),
            title: "Title",
            artist: "Artist",
            album: "Album",
            duration: 42,
            fileName: "file.m4a",
            coverFileName: "cover.jpg",
            format: "M4A",
            contentHash: "hash",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000),
            albumArtist: "Album Artist",
            trackNumber: 3,
            discNumber: 1,
            source: "imported",
            musicPersistentID: "persistent-id"
        )

        let data = try JSONEncoder().encode(track)
        let decoded = try JSONDecoder().decode(Track.self, from: data)

        XCTAssertEqual(decoded, track)
    }

    func testDisplayArtistFallsBackToAlbumArtist() {
        var track = makeTrack(artist: "", albumArtist: "Various Artists")
        XCTAssertEqual(track.displayArtist, "Various Artists")

        track = makeTrack(artist: "Solo", albumArtist: "Various Artists")
        XCTAssertEqual(track.displayArtist, "Solo")
    }

    private func makeTrack(artist: String, albumArtist: String) -> Track {
        Track(
            id: UUID(),
            title: "Title",
            artist: artist,
            album: "Album",
            duration: 1,
            fileName: "file.mp3",
            coverFileName: nil,
            format: "MP3",
            contentHash: "hash",
            dateAdded: Date(timeIntervalSince1970: 0),
            albumArtist: albumArtist
        )
    }
}
