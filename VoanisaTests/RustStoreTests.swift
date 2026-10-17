import XCTest
@testable import Voanisa

final class RustStoreTests: XCTestCase {
    private func makeDatabaseURL() throws -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoanisaTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("library.sqlite"))
    }

    func testSchemaVersionAndEmptyList() throws {
        let (directory, database) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertEqual(try RustStore.schemaVersion(path: database).get(), 1)
        XCTAssertTrue(try RustStore.tracks(path: database).get().isEmpty)
    }

    func testCrudRoundtripThroughBridge() throws {
        let (directory, database) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        var new = RustNewTrack(
            id: "a",
            title: "A",
            fileName: "a.mp3",
            contentHash: "hash-a",
            dateAdded: 0
        )
        new.artist = "Artist"
        new.format = "MP3"

        let inserted = try RustStore.insertTrack(path: database, track: new).get()
        XCTAssertEqual(inserted.id, "a")
        XCTAssertEqual(inserted.artist, "Artist")
        XCTAssertEqual(inserted.sortIndex, 0)

        var update = RustTrackUpdate(id: "a", title: "New")
        update.album = "Album"
        _ = try RustStore.updateTrack(path: database, update: update).get()

        let tracks = try RustStore.tracks(path: database).get()
        XCTAssertEqual(tracks.first?.title, "New")
        XCTAssertEqual(tracks.first?.album, "Album")

        XCTAssertTrue(try RustStore.deleteTrack(path: database, id: "a").get())
        XCTAssertTrue(try RustStore.tracks(path: database).get().isEmpty)
    }

    func testReorderRejectsAnIncompleteList() throws {
        let (directory, database) = try makeDatabaseURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let batch = [
            RustNewTrack(id: "a", title: "A", fileName: "a.mp3", contentHash: "hash-a", dateAdded: 0),
            RustNewTrack(id: "b", title: "B", fileName: "b.mp3", contentHash: "hash-b", dateAdded: 0)
        ]
        _ = try RustStore.insertTracks(path: database, tracks: batch).get()

        XCTAssertThrowsError(try RustStore.reorderTracks(path: database, ids: ["a"]).get())
    }
}
