import Foundation

/// The list that the player should follow for previous/next.
///
/// This mirrors Elysia's rule: the list currently being viewed is the playback
/// order. Search results are only a view of the same list and do not replace it.
enum PlaybackScope: Equatable, Sendable {
    case library
    case playlist(UUID)
}
