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
        new.albumArtist = "Rust Collective"
        new.trackNumber = 3
        new.discNumber = 2
        new.format = "MP3"
        new.source = "local"
        new.musicPersistentID = "persistent-id"
        _ = try RustStore.insertTrack(path: databaseURL, track: new).get()
        try writeJSON([makeTrack(title: "JSON")])

        let tracks = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(tracks.map(\.title), ["SQLite"])
        XCTAssertEqual(tracks.first?.id, id)
        XCTAssertEqual(tracks.first?.artist, "Rust")
        XCTAssertEqual(tracks.first?.albumArtist, "Rust Collective")
        XCTAssertEqual(tracks.first?.trackNumber, 3)
        XCTAssertEqual(tracks.first?.discNumber, 2)
        XCTAssertEqual(tracks.first?.source, "local")
        XCTAssertEqual(tracks.first?.musicPersistentID, "persistent-id")
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

    func testExportWritesAPortableSnapshot() throws {
        var a = makeTrack(title: "A")
        a.albumArtist = "Album Artist"
        a.trackNumber = 1
        a.discNumber = 2
        a.source = "music"
        a.musicPersistentID = "persistent-id"
        let tracks = [a, makeTrack(title: "B")]
        let playlist = Playlist(name: "Favorites", trackIDs: [a.id])
        let destination = directory.appendingPathComponent("export.json")

        try LibraryStore.exportJSON(
            tracks,
            playlists: [playlist],
            to: destination
        )

        let snapshot = try JSONDecoder().decode(
            LibrarySnapshot.self,
            from: Data(contentsOf: destination)
        )
        XCTAssertEqual(snapshot.version, 1)
        XCTAssertEqual(snapshot.tracks, tracks)
        XCTAssertEqual(snapshot.playlists, [playlist])
    }

    func testPlaylistsMigrateAndPersistAlongsideTracks() throws {
        let track = makeTrack(title: "A")
        let playlist = Playlist(name: "Favorites", trackIDs: [track.id])
        try writeJSON([track], playlists: [playlist])

        LibraryStore.migrateIfNeeded([track], databaseURL: databaseURL)
        LibraryStore.migratePlaylistsIfNeeded(
            [playlist],
            tracks: [track],
            databaseURL: databaseURL
        )

        XCTAssertEqual(
            try RustStore.playlists(path: databaseURL).get().first?.trackIDs,
            [track.id.uuidString]
        )
        XCTAssertEqual(
            LibraryStore.loadPlaylists(databaseURL: databaseURL, jsonURL: jsonURL),
            [playlist]
        )

        // A track-only save keeps the SQLite playlists in the JSON backup.
        try LibraryStore.save([track], databaseURL: databaseURL, jsonURL: jsonURL)
        let snapshot = try JSONDecoder().decode(
            LibrarySnapshot.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(snapshot.playlists, [playlist])
    }

    func testSavingWithoutATrackRemovesItEverywhere() throws {
        let kept = makeTrack(title: "Kept")
        let removed = makeTrack(title: "Removed")

        try LibraryStore.save(
            [kept, removed],
            databaseURL: databaseURL,
            jsonURL: jsonURL
        )

        let playlistID = UUID()
        _ = try RustStore.createPlaylist(
            path: databaseURL,
            id: playlistID.uuidString,
            name: "Mix"
        ).get()
        try RustStore.setPlaylistTracks(
            path: databaseURL,
            id: playlistID.uuidString,
            trackIDs: [kept.id.uuidString, removed.id.uuidString]
        ).get()

        // Deleting a track is just a save without it: the row disappears from
        // SQLite and the foreign key cascade drops the playlist membership.
        try LibraryStore.save([kept], databaseURL: databaseURL, jsonURL: jsonURL)

        XCTAssertEqual(
            try RustStore.tracks(path: databaseURL).get().map(\.id),
            [kept.id.uuidString]
        )
        XCTAssertEqual(
            try RustStore.playlists(path: databaseURL).get().first?.trackIDs,
            [kept.id.uuidString]
        )
        XCTAssertEqual(
            LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL).map(\.id),
            [kept.id]
        )
    }

    func testFullMetadataRoundTripsThroughSQLite() throws {
        var track = makeTrack(title: "Full")
        track.albumArtist = "Album Artist"
        track.trackNumber = 4
        track.discNumber = 1
        track.source = "music"
        track.musicPersistentID = "persistent-id"

        try LibraryStore.save([track], databaseURL: databaseURL, jsonURL: jsonURL)

        let loaded = LibraryStore.load(databaseURL: databaseURL, jsonURL: jsonURL)
        XCTAssertEqual(loaded, [track])
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

    private func writeJSON(
        _ tracks: [Track],
        playlists: [Playlist] = []
    ) throws {
        let snapshot = LibrarySnapshot(tracks: tracks, playlists: playlists)
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
