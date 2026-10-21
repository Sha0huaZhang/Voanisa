import Foundation

/// Hard limits for the free-text fields the user can type into.
///
/// They exist for stability, not for tidiness. SwiftUI lays text out on the main
/// thread, and the cost grows faster than the string does: pasting ~40 000
/// characters into a playlist name made the stress build spin at 100% CPU while
/// memory climbed into the gigabytes (12 GB, with 8 GB of swap on a 16 GB Mac).
/// The same string then reached the sidebar, the playlist header and the SQLite
/// row, so every one of them had to re-lay it out.
///
/// The values here are far above anything a real name needs, and they cut on
/// grapheme-cluster boundaries so emoji and CJK characters are never split.
enum LibraryLimits {
    static let playlistName = 100
    static let trackTitle = 300
    static let trackArtist = 300
    static let trackAlbum = 300

    /// Trims surrounding whitespace and cuts to at most `limit` characters.
    static func normalized(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard limit > 0, trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }
}
