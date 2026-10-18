import XCTest
@testable import Voanisa

/// Editing metadata must reach the file, not just `library.sqlite`, so dragging
/// an imported song into another player shows the same title and artist.
final class RustTagWriteTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    func testWritesTagsIntoTheFile() throws {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-tags-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("tagged.m4a"),
            to: copy
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        var tags = RustTagWrite(track: makeTrack())
        tags.title = "Edited Title"
        tags.artist = "Edited Artist"
        tags.album = "Edited Album"
        tags.albumArtist = "Edited Album Artist"
        tags.trackNumber = 5
        tags.discNumber = 2

        XCTAssertTrue(RustCore.writeTags(url: copy, tags: tags))

        let reread = try XCTUnwrap(RustCore.tags(url: copy))
        XCTAssertEqual(reread.title, "Edited Title")
        XCTAssertEqual(reread.artist, "Edited Artist")
        XCTAssertEqual(reread.album, "Edited Album")
        XCTAssertEqual(reread.albumArtist, "Edited Album Artist")
        XCTAssertEqual(reread.trackNumber, 5)
        XCTAssertEqual(reread.discNumber, 2)
    }

    func testEmptyValuesClearTheTags() throws {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-clear-\(UUID().uuidString).m4a")
        try FileManager.default.copyItem(
            at: fixtures.appendingPathComponent("tagged.m4a"),
            to: copy
        )
        defer { try? FileManager.default.removeItem(at: copy) }

        var tags = RustTagWrite(track: makeTrack())
        tags.title = ""
        tags.artist = ""
        tags.album = ""
        tags.albumArtist = ""
        tags.trackNumber = nil
        tags.discNumber = nil

        XCTAssertTrue(RustCore.writeTags(url: copy, tags: tags))

        let reread = try XCTUnwrap(RustCore.tags(url: copy))
        XCTAssertNil(reread.title)
        XCTAssertNil(reread.album)
    }

    func testMissingFileFails() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-missing-\(UUID().uuidString).m4a")
        XCTAssertFalse(RustCore.writeTags(url: url, tags: RustTagWrite(track: makeTrack())))
    }

    private func makeTrack() -> Track {
        Track(
            id: UUID(),
            title: "Original",
            artist: "",
            album: "",
            duration: 1,
            fileName: "original.m4a",
            coverFileName: nil,
            format: "M4A",
            contentHash: "hash",
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }
}
