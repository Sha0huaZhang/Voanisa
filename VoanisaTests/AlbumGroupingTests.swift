import XCTest
@testable import Voanisa

final class AlbumGroupingTests: XCTestCase {
    func testGroupsByAlbumAndAlbumArtist() {
        let tracks = [
            make(title: "B", artist: "Track B", album: "Album", albumArtist: "Various", disc: 1, track: 2),
            make(title: "A", artist: "Track A", album: "Album", albumArtist: "Various", disc: 1, track: 1),
            make(title: "Solo", artist: "Solo Artist", album: "Album", albumArtist: "", disc: 1, track: 3)
        ]

        let groups = AlbumGrouping.groups(
            from: tracks,
            unknownAlbum: "Unknown",
            unknownArtist: "Unknown Artist"
        )

        XCTAssertEqual(groups.count, 2)
        let various = groups.first { $0.artist == "Various" }
        XCTAssertEqual(various?.tracks.map(\.title), ["A", "B"])
        XCTAssertEqual(various?.title, "Album")
        XCTAssertEqual(groups.first { $0.artist == "Solo Artist" }?.tracks.count, 1)
    }

    func testEmptyAlbumUsesUnknownLabel() {
        let groups = AlbumGrouping.groups(
            from: [make(title: "Song", artist: "", album: "", albumArtist: "")],
            unknownAlbum: "Unknown Album",
            unknownArtist: "Unknown Artist"
        )

        XCTAssertEqual(groups.first?.title, "Unknown Album")
        XCTAssertEqual(groups.first?.artist, "Unknown Artist")
    }

    func testSortsByDiscThenTrack() {
        let tracks = [
            make(title: "Third", disc: 2, track: 1),
            make(title: "Second", disc: 1, track: 2),
            make(title: "First", disc: 1, track: 1)
        ]

        let group = AlbumGrouping.groups(from: tracks).first

        XCTAssertEqual(group?.tracks.map(\.title), ["First", "Second", "Third"])
    }

    func testUnknownTrackNumberSortsLast() {
        let tracks = [
            make(title: "No Number", track: nil),
            make(title: "First", track: 1)
        ]

        let group = AlbumGrouping.groups(from: tracks).first

        XCTAssertEqual(group?.tracks.map(\.title), ["First", "No Number"])
    }

    func testRepresentativeTrackPrefersACover() {
        let tracks = [
            make(title: "No Cover", cover: nil),
            make(title: "With Cover", cover: "cover.jpg")
        ]

        let group = AlbumGrouping.groups(from: tracks).first

        XCTAssertEqual(group?.representativeTrack?.title, "With Cover")
    }

    private func make(
        title: String,
        artist: String = "Artist",
        album: String = "Album",
        albumArtist: String = "",
        disc: Int? = nil,
        track: Int? = nil,
        cover: String? = nil
    ) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: artist,
            album: album,
            duration: 1,
            fileName: "\(title).mp3",
            coverFileName: cover,
            format: "MP3",
            contentHash: "hash-\(title)",
            dateAdded: Date(timeIntervalSince1970: 0),
            albumArtist: albumArtist,
            trackNumber: track,
            discNumber: disc
        )
    }
}
