import Foundation

/// Persistence for the local library.
///
/// SQLite is the primary store. The portable JSON snapshot remains the fallback
/// while the storage migration is in progress, so an interrupted migration can
/// never hide an existing library.
struct LibrarySnapshot: Codable {
    var version: Int = 1
    var tracks: [Track]
    var playlists: [Playlist] = []

    init(version: Int = 1, tracks: [Track], playlists: [Playlist] = []) {
        self.version = version
        self.tracks = tracks
        self.playlists = playlists
    }

    enum CodingKeys: String, CodingKey {
        case version, tracks, playlists
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        tracks = try container.decode([Track].self, forKey: .tracks)
        playlists = try container.decodeIfPresent([Playlist].self, forKey: .playlists) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(tracks, forKey: .tracks)
        try container.encode(playlists, forKey: .playlists)
    }
}

enum LibraryStore {
    /// Loads the library, preferring SQLite when it contains tracks.
    ///
    /// A missing, empty or unreadable database falls back to `library.json`.
    static func load() -> [Track] {
        load(
            databaseURL: LibraryLocation.databaseURL,
            jsonURL: LibraryLocation.libraryFileURL
        )
    }

    static func load(databaseURL: URL, jsonURL: URL) -> [Track] {
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            switch RustStore.tracks(path: databaseURL) {
            case .success(let records):
                let tracks = records.compactMap { track(from: $0) }
                if !tracks.isEmpty {
                    Diagnostics.log("Loaded \(tracks.count) tracks from SQLite")
                    return tracks
                }
                Diagnostics.log("SQLite library is empty; falling back to library.json")
            case .failure(let error):
                Diagnostics.error(error.localizedDescription, context: "library.sqlite.read")
            }
        }
        // Restore the snapshot through the core first: it writes SQLite, which
        // then becomes the single place the rest of the app reads from. The
        // Swift decoder remains for a snapshot the core cannot parse.
        if FileManager.default.fileExists(atPath: jsonURL.path),
           let counts = RustStore.importSnapshot(from: jsonURL, database: databaseURL),
           counts.tracks > 0 || counts.playlists > 0,
           case .success(let records) = RustStore.tracks(path: databaseURL) {
            let restored = records.compactMap { track(from: $0) }
            if !restored.isEmpty {
                Diagnostics.log("从 library.json 恢复了 \(restored.count) 首")
                return restored
            }
        }

        return loadSnapshot(url: jsonURL)?.tracks ?? []
    }

    /// Loads playlists, preferring SQLite and falling back to the JSON snapshot
    /// for libraries created before playlists existed.
    static func loadPlaylists() -> [Playlist] {
        loadPlaylists(
            databaseURL: LibraryLocation.databaseURL,
            jsonURL: LibraryLocation.libraryFileURL
        )
    }

    static func loadPlaylists(databaseURL: URL, jsonURL: URL) -> [Playlist] {
        if let playlists = playlistsFromDatabase(path: databaseURL), !playlists.isEmpty {
            Diagnostics.log("Loaded \(playlists.count) playlists from SQLite")
            return playlists
        }
        return loadSnapshot(url: jsonURL)?.playlists ?? []
    }

    private static func playlistsFromDatabase(path: URL) -> [Playlist]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }

        switch RustStore.playlists(path: path) {
        case .success(let records):
            return records.compactMap { playlist(from: $0) }
        case .failure(let error):
            Diagnostics.error(error.localizedDescription, context: "library.playlists.read")
            return nil
        }
    }

    static func save(_ tracks: [Track], playlists: [Playlist]? = nil) throws {
        try LibraryLocation.ensureDirectories()
        try save(
            tracks,
            playlists: playlists,
            databaseURL: LibraryLocation.databaseURL,
            jsonURL: LibraryLocation.libraryFileURL
        )
    }

    /// Writes SQLite first, then the portable JSON snapshot.
    ///
    /// If the database cannot be written it is moved aside and the snapshot is
    /// still saved, so a broken database neither blocks persistence nor gets
    /// preferred over the snapshot on the next launch.
    static func save(
        _ tracks: [Track],
        playlists: [Playlist]? = nil,
        databaseURL: URL,
        jsonURL: URL
    ) throws {
        var databaseError: Error?
        do {
            try saveDatabase(tracks, path: databaseURL)
        } catch {
            databaseError = error
            discardDatabase(at: databaseURL)
        }

        let playlistsToWrite = playlists
            ?? playlistsFromDatabase(path: databaseURL)
            ?? loadSnapshot(url: jsonURL)?.playlists
            ?? []
        let trackIDs = Set(tracks.map(\.id))
        let reconciled = playlistsToWrite.map { playlist in
            var copy = playlist
            copy.trackIDs = copy.trackIDs.filter(trackIDs.contains)
            return copy
        }

        // The Rust core owns the snapshot format now; the Swift encoder stays as
        // a fallback for the case where the database itself was unusable. The
        // core must not run against a discarded database: opening it would
        // create an empty one and export nothing.
        var snapshotWritten = false
        if databaseError == nil {
            snapshotWritten = RustStore.exportSnapshot(database: databaseURL, to: jsonURL) != nil
        }
        if !snapshotWritten {
            try saveJSON(tracks: tracks, playlists: reconciled, url: jsonURL)
        }

        if let databaseError {
            throw databaseError
        }
    }

    /// Writes a portable snapshot to an arbitrary location.
    static func exportJSON(
        _ tracks: [Track],
        playlists: [Playlist] = [],
        to url: URL
    ) throws {
        try saveJSON(tracks: tracks, playlists: playlists, url: url)
    }

    /// Imports an existing `library.json` into an empty database.
    ///
    /// Runs once at launch; later saves keep both stores in sync.
    static func migrateIfNeeded(_ tracks: [Track]) {
        migrateIfNeeded(tracks, databaseURL: LibraryLocation.databaseURL)
    }

    static func migrateIfNeeded(_ tracks: [Track], databaseURL: URL) {
        guard !tracks.isEmpty else { return }
        do {
            let existing = try RustStore.tracks(path: databaseURL).get()
            guard existing.isEmpty else { return }
            try saveDatabase(tracks, path: databaseURL)
            Diagnostics.log("Migrated \(tracks.count) tracks to SQLite")
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.migrate")
        }
    }

    /// Migrates playlist snapshots after their tracks are present in SQLite.
    static func migratePlaylistsIfNeeded(_ playlists: [Playlist], tracks: [Track]) {
        migratePlaylistsIfNeeded(
            playlists,
            tracks: tracks,
            databaseURL: LibraryLocation.databaseURL
        )
    }

    static func migratePlaylistsIfNeeded(
        _ playlists: [Playlist],
        tracks: [Track],
        databaseURL: URL
    ) {
        guard !playlists.isEmpty else { return }
        do {
            let existing = try RustStore.playlists(path: databaseURL).get()
            guard existing.isEmpty else { return }

            let validIDs = Set(tracks.map(\.id))
            for playlist in playlists {
                let name = playlist.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }

                _ = try RustStore.createPlaylist(
                    path: databaseURL,
                    id: playlist.id.uuidString,
                    name: name
                ).get()

                let trackIDs = playlist.trackIDs
                    .filter(validIDs.contains)
                    .map(\.uuidString)
                if !trackIDs.isEmpty {
                    try RustStore.setPlaylistTracks(
                        path: databaseURL,
                        id: playlist.id.uuidString,
                        trackIDs: trackIDs
                    ).get()
                }
            }
            Diagnostics.log("Migrated \(playlists.count) playlists to SQLite")
        } catch {
            Diagnostics.error(
                error.localizedDescription,
                context: "library.playlists.migrate"
            )
        }
    }

    private static func saveJSON(
        tracks: [Track],
        playlists: [Playlist],
        url: URL
    ) throws {
        let snapshot = LibrarySnapshot(tracks: tracks, playlists: playlists)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    /// Makes the database match the in-memory list in one transaction.
    private static func saveDatabase(_ tracks: [Track], path: URL) throws {
        try RustStore.syncTracks(path: path, tracks: tracks.map(\.rustRecord)).get()
    }

    /// Moves an unusable database (and its WAL files) out of the way.
    private static func discardDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: url.path + suffix)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }

            let destination = URL(fileURLWithPath: url.path + ".failed" + suffix)
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: source, to: destination)
            } catch {
                Diagnostics.error(
                    error.localizedDescription,
                    context: "library.sqlite.discard"
                )
                try? FileManager.default.removeItem(at: source)
            }
        }
    }

    private static func loadSnapshot(url: URL) -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else {
            return nil
        }
        return snapshot
    }

    private static func playlist(from record: RustPlaylist) -> Playlist? {
        guard let id = UUID(uuidString: record.id) else {
            Diagnostics.error(
                "Ignoring playlist with invalid id: \(record.id)",
                context: "library.sqlite"
            )
            return nil
        }
        let trackIDs = record.trackIDs.compactMap { UUID(uuidString: $0) }
        return Playlist(id: id, name: record.name, trackIDs: trackIDs)
    }

    /// Converts a SQLite row into the UI model.
    ///
    /// `date_added` is stored as seconds since the Unix epoch.
    private static func track(from record: RustTrack) -> Track? {
        guard let id = UUID(uuidString: record.id) else {
            Diagnostics.error("Ignoring track with invalid id: \(record.id)", context: "library.sqlite")
            return nil
        }
        return Track(
            id: id,
            title: record.title,
            artist: record.artist,
            album: record.album,
            duration: record.duration,
            fileName: record.fileName,
            coverFileName: record.coverFileName,
            format: record.format,
            contentHash: record.contentHash,
            dateAdded: Date(timeIntervalSince1970: record.dateAdded),
            albumArtist: record.albumArtist,
            trackNumber: record.trackNumber,
            discNumber: record.discNumber,
            source: record.source,
            musicPersistentID: record.musicPersistentID
        )
    }
}

private extension Track {
    /// The SQLite projection of this track. `date_added` uses Unix seconds.
    var rustRecord: RustNewTrack {
        var record = RustNewTrack(
            id: id.uuidString,
            title: title,
            fileName: fileName,
            contentHash: contentHash,
            dateAdded: dateAdded.timeIntervalSince1970
        )
        record.artist = artist
        record.album = album
        record.albumArtist = albumArtist
        record.trackNumber = trackNumber
        record.discNumber = discNumber
        record.duration = duration
        record.coverFileName = coverFileName
        record.format = format
        record.source = source
        record.musicPersistentID = musicPersistentID
        return record
    }
}
