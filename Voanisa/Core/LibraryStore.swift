import Foundation

/// Persistence for the local library.
///
/// SQLite is the primary store. The portable JSON snapshot remains the fallback
/// while the storage migration is in progress, so an interrupted migration can
/// never hide an existing library.
struct LibrarySnapshot: Codable {
    var version: Int = 1
    var tracks: [Track]
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
        return loadJSON(url: jsonURL)
    }

    static func save(_ tracks: [Track]) throws {
        try LibraryLocation.ensureDirectories()
        try save(
            tracks,
            databaseURL: LibraryLocation.databaseURL,
            jsonURL: LibraryLocation.libraryFileURL
        )
    }

    /// Writes SQLite first, then the portable JSON snapshot.
    ///
    /// If the database cannot be written it is moved aside and the snapshot is
    /// still saved, so a broken database neither blocks persistence nor gets
    /// preferred over the snapshot on the next launch.
    static func save(_ tracks: [Track], databaseURL: URL, jsonURL: URL) throws {
        var databaseError: Error?
        do {
            try saveDatabase(tracks, path: databaseURL)
        } catch {
            databaseError = error
            discardDatabase(at: databaseURL)
        }

        try saveJSON(tracks, url: jsonURL)

        if let databaseError {
            throw databaseError
        }
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

    private static func saveJSON(_ tracks: [Track], url: URL) throws {
        let snapshot = LibrarySnapshot(tracks: tracks)
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

    private static func loadJSON(url: URL) -> [Track] {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else {
            return []
        }
        return snapshot.tracks
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
            dateAdded: Date(timeIntervalSince1970: record.dateAdded)
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
        record.duration = duration
        record.coverFileName = coverFileName
        record.format = format
        return record
    }
}
