import Foundation

struct AlbumGroup: Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let tracks: [Track]

    var representativeTrack: Track? {
        tracks.first { $0.coverFileName != nil } ?? tracks.first
    }
}

enum AlbumGrouping {
    static func groups(
        from tracks: [Track],
        unknownAlbum: String = String(localized: "albums.unknown"),
        unknownArtist: String = String(localized: "track.unknownArtist")
    ) -> [AlbumGroup] {
        struct Draft {
            var title: String
            var artist: String
            var tracks: [Track]
        }

        var drafts: [String: Draft] = [:]

        for track in tracks {
            let album = track.album.trimmingCharacters(in: .whitespacesAndNewlines)
            let albumArtist = track.albumArtist
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = albumArtist.isEmpty
                ? track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
                : albumArtist
            let title = album.isEmpty ? unknownAlbum : album
            let resolvedArtist = artist.isEmpty ? unknownArtist : artist
            let key = "\(title.lowercased())\u{1F}\(resolvedArtist.lowercased())"

            if drafts[key] == nil {
                drafts[key] = Draft(title: title, artist: resolvedArtist, tracks: [])
            }
            drafts[key]?.tracks.append(track)
        }

        return drafts.map { key, draft in
            AlbumGroup(
                id: key,
                title: draft.title,
                artist: draft.artist,
                tracks: sort(draft.tracks)
            )
        }
        .sorted { lhs, rhs in
            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }
            return lhs.artist.localizedStandardCompare(rhs.artist) == .orderedAscending
        }
    }

    private static func sort(_ tracks: [Track]) -> [Track] {
        tracks.sorted { lhs, rhs in
            let lhsDisc = lhs.discNumber ?? 0
            let rhsDisc = rhs.discNumber ?? 0
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsTrack = lhs.trackNumber ?? Int.max
            let rhsTrack = rhs.trackNumber ?? Int.max
            if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
