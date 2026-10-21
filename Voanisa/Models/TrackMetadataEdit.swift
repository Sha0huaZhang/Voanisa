import Foundation

/// Editable metadata for a song. File identity, duration and content hash stay
/// untouched.
struct TrackMetadataEdit: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var albumArtist: String
    var trackNumber: Int?
    var discNumber: Int?

    init(track: Track) {
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        trackNumber = track.trackNumber
        discNumber = track.discNumber
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applying(to track: Track) -> Track {
        var updated = track
        updated.title = LibraryLimits.normalized(title, limit: LibraryLimits.trackTitle)
        updated.artist = LibraryLimits.normalized(artist, limit: LibraryLimits.trackArtist)
        updated.album = LibraryLimits.normalized(album, limit: LibraryLimits.trackAlbum)
        updated.albumArtist = LibraryLimits.normalized(albumArtist, limit: LibraryLimits.trackArtist)
        updated.trackNumber = trackNumber
        updated.discNumber = discNumber
        return updated
    }
}

/// A cover change requested by the editor.
enum TrackCoverEdit: Sendable {
    case keep
    case replace(jpeg: Data, original: Data?)
    case remove
}
