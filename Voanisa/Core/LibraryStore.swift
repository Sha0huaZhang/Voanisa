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
        let snapshot = LibrarySnapshot(tracks: tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: LibraryLocation.libraryFileURL, options: .atomic)
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
