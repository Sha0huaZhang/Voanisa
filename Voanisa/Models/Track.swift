import Foundation

/// One audio file is one song in Voanisa.
///
/// The database stores only the relative file name; the library folder can be
/// moved or backed up as a whole without rewriting absolute paths.
struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var fileName: String
    var coverFileName: String?
    var format: String
    var contentHash: String
    var dateAdded: Date

    var displayArtist: String {
        artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "track.unknownArtist")
            : artist
    }
}
