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

    private func writeJSON(_ tracks: [Track]) throws {
        let snapshot = LibrarySnapshot(tracks: tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: jsonURL, options: .atomic)
    }

    private func makeTrack(title: String) -> Track {
        Track(
            id: UUID(),
            title: title,
            artist: "",
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
