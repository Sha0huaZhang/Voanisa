import Foundation

/// Prototype persistence.
///
/// The on-disk contract is deliberately simple and portable: a JSON snapshot
/// with relative file names and UUID identifiers. Replacing this with SQLite
/// later does not change the rest of the app.
struct LibrarySnapshot: Codable {
    var version: Int = 1
    var tracks: [Track]
}

enum LibraryStore {
    static func load() -> [Track] {
        guard let data = try? Data(contentsOf: LibraryLocation.libraryFileURL),
              let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) else {
            return []
        }
        return snapshot.tracks
    }

    static func save(_ tracks: [Track]) throws {
        try LibraryLocation.ensureDirectories()
        let snapshot = LibrarySnapshot(tracks: tracks)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: LibraryLocation.libraryFileURL, options: .atomic)
    }
}
