import Foundation

/// Pure previous/next maths, adapted from Elysia's SongAdvance.
///
/// The order always comes from Voanisa's own active list (the song list, a
/// playlist, or an album), never from an external queue. A missing anchor means
/// "do not move": guessing a starting point would jump to an unrelated song.
enum SongAdvance {
    static func targetIndex(
        anchorIndex: Int?,
        count: Int,
        offset: Int,
        repeatAll: Bool
    ) -> Int? {
        guard count > 0, let anchor = anchorIndex else { return nil }

        let candidate = anchor + offset

        if candidate < 0 {
            return repeatAll ? count - 1 : nil
        }
        if candidate >= count {
            return repeatAll ? 0 : nil
        }
        return candidate
    }
}

enum PlaybackNavigation {
    /// Maps the playing track to its neighbour in the active list.
    ///
    /// The critical rule: if the current track is not in the active list, return
    /// nil. Picking a fallback would jump to an unrelated song when the user is
    /// viewing a playlist or album that does not contain the playing track.
    static func targetID(
        currentID: UUID?,
        trackIDs: [UUID],
        offset: Int,
        repeatAll: Bool
    ) -> UUID? {
        guard let currentID,
              let index = trackIDs.firstIndex(of: currentID) else {
            return nil
        }
        guard let target = SongAdvance.targetIndex(
            anchorIndex: index,
            count: trackIDs.count,
            offset: offset,
            repeatAll: repeatAll
        ) else {
            return nil
        }
        return trackIDs[target]
    }
}
