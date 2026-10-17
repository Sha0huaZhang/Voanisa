import XCTest
@testable import Voanisa

final class LibraryStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoanisaLibraryStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private var databaseURL: URL {
        directory.appendingPathComponent("library.sqlite")
    }

    private var jsonURL: URL {
        directory.appendingPathComponent("library.json")
    }

    func testDatabaseTakesPrecedenceOverJSON() throws {
        let id = UUID()
        var new = RustNewTrack(
            id: id.uuidString,
            title: "SQLite",
            fileName: "sqlite.mp3",
            contentHash: "hash-sqlite",
            dateAdded: 1_700_000_000
        )
        new.artist = "Rust"
        new.format = "MP3"
        _ = try RustStore.insertTrack(path: databaseURL, track: new).get()
        try writeJSON([makeTrack(title: "JSON")])

        let tracks = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(tracks.map(\.title), ["SQLite"])
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.artist, "Rust")
        XCTAssertEqual(tracks.first?.fileName, "sqlite.mp3")
        XCTAssertEqual(
            tracks.first?.dateAdded,
            Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    func testFallsBackToJSONWhenDatabaseIsMissing() throws {
        try writeJSON([makeTrack(title: "JSON")])

        let tracks = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(tracks.map(\.title), ["JSON"])
    }

    func testFallsBackToJSONWhenDatabaseIsEmpty() throws {
        // Opening the store creates the schema, but no rows.
        XCTAssertTrue(try RustStore.tracks(path: databaseURL).get().isEmpty)
        try writeJSON([makeTrack(title: "JSON")])

        let tracks = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(tracks.map(\.title), ["JSON"])
    }

    func testFallsBackToJSONWhenDatabaseIsUnreadable() throws {
        try Data("not a database".utf8).write(to: databaseURL, options: .atomic)
        try writeJSON([makeTrack(title: "JSON")])

        let tracks = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(tracks.map(\.title), ["JSON"])
    }

    func testSaveFallsBackToJSONWhenDatabaseIsUnreadable() throws {
        try Data("not a database".utf8).write(to: databaseURL, options: .atomic)
        let tracks = [makeTrack(title: "A")]

        XCTAssertThrowsError(
            try LibraryStore.save(tracks, databaseURL: databaseURL, jsonURL: jsonURL)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))
        XCTAssertEqual(
            LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL).map(\.title),
            ["A"]
        )

        // The next launch migrates the snapshot into a fresh database.
        LibraryStore.migrateIfNeeded(tracks, databaseURL: databaseURL)
        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().count, 1)
    }

    func testSaveMirrorsTrackChangesAndOrder() throws {
        let a = makeTrack(title: "A")
        let b = makeTrack(title: "B")
        try LibraryStore.save([a, b], databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().map(\.id), [
            a.id.uuidString,
            b.id.uuidString
        ])

        var renamed = a
        renamed.title = "A2"
        renamed.artist = "Artist"
        try LibraryStore.save([renamed, b], databaseURL: databaseURL, jsonURL: jsonURL)

        let updated = try RustStore.tracks(path: databaseURL).get()
        XCTAssertEqual(updated.map(\.title), ["A2", "B"])
        XCTAssertEqual(updated.first?.artist, "Artist")

        let c = makeTrack(title: "C")
        try LibraryStore.save([renamed, b, c], databaseURL: databaseURL, jsonURL: jsonURL)
        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().count, 3)

        try LibraryStore.save([c, renamed, b], databaseURL: databaseURL, jsonURL: jsonURL)
        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().map(\.id), [
            c.id.uuidString,
            renamed.id.uuidString,
            b.id.uuidString
        ])

        try LibraryStore.save([c, b], databaseURL: databaseURL, jsonURL: jsonURL)
        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().map(\.id), [
            c.id.uuidString,
            b.id.uuidString
        ])

        let snapshot = try JSONDecoder().decode(
            LibrarySnapshot.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(snapshot.tracks.map(\.id), [c.id, b.id])
    }

    func testMigrationCopiesJSONTracksIntoEmptyDatabase() throws {
        let tracks = [makeTrack(title: "A"), makeTrack(title: "B")]
        try writeJSON(tracks)
        XCTAssertFalse(FileManager.default.fileExists(atPath: databaseURL.path))

        LibraryStore.migrateIfNeeded(tracks, databaseURL: databaseURL)

        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().map(\.id), [
            tracks[0].id.uuidString,
            tracks[1].id.uuidString
        ])
        XCTAssertEqual(
            LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL).map(\.id),
            tracks.map(\.id)
        )

        // A second launch must not duplicate the rows.
        LibraryStore.migrateIfNeeded(tracks, databaseURL: databaseURL)
        XCTAssertEqual(try RustStore.tracks(path: databaseURL).get().count, 2)
    }

    private func writeJSON(_ tracks: [Track]) throws {
        let snapshot = LibrarySnapshot(tracks: tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: jsonURL, options: .atomic)
    }

    private func makeTrack(
        id: UUID = UUID(),
        title: String,
        artist: String = ""
    ) -> Track {
        Track(
            id: id,
            title: title,
            artist: artist,
            album: "",
            duration: 1,
            fileName: "\(title).mp3",
            coverFileName: nil,
            format: "MP3",
            contentHash: "hash-\(title)",
            dateAdded: Date(timeIntervalSince1970: 0)
        )
    }
}
