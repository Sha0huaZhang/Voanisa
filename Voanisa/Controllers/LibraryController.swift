import AppKit
import Foundation

/// Owns the local library: tracks, search text, persistence, file trash and
/// artwork cache. Playback and import orchestration stay in AppModel.
@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published private(set) var playlists: [Playlist] = []
    @Published var searchText = ""

    var onError: ((String) -> Void)?

    private let artworkCache = NSCache<NSString, NSImage>()

    init() {
        do {
            try LibraryLocation.ensureDirectories()
        } catch {
            Diagnostics.log("无法创建曲库目录：\(error.localizedDescription)")
        }
        tracks = LibraryStore.load()
        LibraryStore.migrateIfNeeded(tracks)
        playlists = LibraryStore.loadPlaylists()
        LibraryStore.migratePlaylistsIfNeeded(playlists, tracks: tracks)
    }

    var visibleTracks: [Track] {
        SongSearch.filter(tracks, query: searchText)
    }

    func track(id: UUID?) -> Track? {
        guard let id else { return nil }
        return tracks.first { $0.id == id }
    }

    func append(_ newTracks: [Track]) {
        tracks.append(contentsOf: newTracks)
        save()
    }

    func reorder(_ newTracks: [Track]) {
        tracks = newTracks
        save()
    }

    func save() {
        do {
            try LibraryStore.save(tracks, playlists: playlists)
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.save")
            onError?(error.localizedDescription)
        }
    }

    func exportLibrary(to url: URL) {
        do {
            try LibraryStore.exportJSON(tracks, playlists: playlists, to: url)
            Diagnostics.log("Exported \(tracks.count) tracks to \(url.path)")
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.export")
            onError?(error.localizedDescription)
        }
    }

    @discardableResult
    func updateMetadata(
        _ track: Track,
        edit: TrackMetadataEdit,
        cover: TrackCoverEdit
    ) -> Track? {
        guard edit.isValid,
              let index = tracks.firstIndex(where: { $0.id == track.id }) else {
            return nil
        }

        do {
            var updated = edit.applying(to: tracks[index])
            // A fresh rendered name bypasses any in-memory image cache in the rows.
            let coverName = "\(track.id.uuidString)-\(UUID().uuidString.prefix(8)).jpg"
            let originalName = "\(track.id.uuidString).jpg"

            switch cover {
            case .keep:
                break

            case .replace(let jpeg, let original):
                try jpeg.write(
                    to: LibraryLocation.coverURL(for: coverName),
                    options: .atomic
                )
                if let oldName = updated.coverFileName, oldName != coverName {
                    try? FileManager.default.trashItem(
                        at: LibraryLocation.coverURL(for: oldName),
                        resultingItemURL: nil
                    )
                }
                updated.coverFileName = coverName

                if let original {
                    do {
                        try original.write(
                            to: LibraryLocation.originalCoversURL
                                .appendingPathComponent(originalName),
                            options: .atomic
                        )
                        removeOriginalCovers(for: track.id, keeping: originalName)
                    } catch {
                        Diagnostics.error(
                            error.localizedDescription,
                            context: "library.metadata.originalCover"
                        )
                    }
                } else {
                    removeOriginalCovers(for: track.id)
                }

            case .remove:
                if let oldName = updated.coverFileName {
                    try? FileManager.default.trashItem(
                        at: LibraryLocation.coverURL(for: oldName),
                        resultingItemURL: nil
                    )
                }
                removeOriginalCovers(for: track.id)
                updated.coverFileName = nil
            }

            tracks[index] = updated
            artworkCache.removeObject(forKey: track.id.uuidString as NSString)
            save()
            Diagnostics.log("更新《\(updated.title)》的元数据")
            return updated
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.metadata")
            onError?(error.localizedDescription)
            return nil
        }
    }

    // MARK: - Playlists

    func playlist(id: UUID) -> Playlist? {
        playlists.first { $0.id == id }
    }

    func tracks(in playlist: Playlist) -> [Track] {
        playlist.trackIDs.compactMap { track(id: $0) }
    }

    @discardableResult
    func createPlaylist(name: String) -> Playlist? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let playlist = Playlist(name: trimmed)
        do {
            _ = try RustStore.createPlaylist(
                path: LibraryLocation.databaseURL,
                id: playlist.id.uuidString,
                name: playlist.name
            ).get()
            playlists.append(playlist)
            save()
            Diagnostics.log("创建歌单《\(playlist.name)》")
            return playlist
        } catch {
            reportPlaylistError(error, context: "library.playlist.create")
            return nil
        }
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = playlists.firstIndex(where: { $0.id == playlist.id }) else {
            return
        }

        do {
            try RustStore.renamePlaylist(
                path: LibraryLocation.databaseURL,
                id: playlist.id.uuidString,
                name: trimmed
            ).get()
            playlists[index].name = trimmed
            save()
        } catch {
            reportPlaylistError(error, context: "library.playlist.rename")
        }
    }

    func deletePlaylist(_ playlist: Playlist) {
        do {
            _ = try RustStore.deletePlaylist(
                path: LibraryLocation.databaseURL,
                id: playlist.id.uuidString
            ).get()
            playlists.removeAll { $0.id == playlist.id }
            save()
            Diagnostics.log("删除歌单《\(playlist.name)》")
        } catch {
            reportPlaylistError(error, context: "library.playlist.delete")
        }
    }

    func add(_ track: Track, to playlistID: UUID) {
        guard let playlist = playlist(id: playlistID),
              !playlist.trackIDs.contains(track.id) else {
            return
        }
        setPlaylistTracks(playlist.trackIDs + [track.id], for: playlistID)
    }

    func remove(_ track: Track, from playlistID: UUID) {
        guard let playlist = playlist(id: playlistID) else { return }
        setPlaylistTracks(
            playlist.trackIDs.filter { $0 != track.id },
            for: playlistID
        )
    }

    private func setPlaylistTracks(_ trackIDs: [UUID], for playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else {
            return
        }

        var seen = Set<UUID>()
        let unique = trackIDs.filter { seen.insert($0).inserted }

        do {
            try RustStore.setPlaylistTracks(
                path: LibraryLocation.databaseURL,
                id: playlistID.uuidString,
                trackIDs: unique.map(\.uuidString)
            ).get()
            playlists[index].trackIDs = unique
            save()
        } catch {
            reportPlaylistError(error, context: "library.playlist.tracks")
        }
    }

    private func reportPlaylistError(_ error: Error, context: String) {
        Diagnostics.error(error.localizedDescription, context: context)
        onError?(error.localizedDescription)
    }

    private func removeOriginalCovers(for id: UUID, keeping keptName: String? = nil) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: LibraryLocation.originalCoversURL,
            includingPropertiesForKeys: nil
        ) else {
            return
        }

        for file in files {
            guard file.deletingPathExtension().lastPathComponent == id.uuidString else {
                continue
            }
            guard file.lastPathComponent != keptName else { continue }
            try? FileManager.default.trashItem(at: file, resultingItemURL: nil)
        }
    }

    func remove(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
        for index in playlists.indices {
            playlists[index].trackIDs.removeAll { $0 == track.id }
        }
        save()

        do {
            try FileManager.default.trashItem(
                at: LibraryLocation.mediaURL(for: track.fileName),
                resultingItemURL: nil
            )
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.trash.audio")
        }
        if let cover = track.coverFileName {
            do {
                try FileManager.default.trashItem(
                    at: LibraryLocation.coverURL(for: cover),
                    resultingItemURL: nil
                )
            } catch {
                Diagnostics.error(error.localizedDescription, context: "library.trash.cover")
            }
        }
        artworkCache.removeObject(forKey: track.id.uuidString as NSString)
        Diagnostics.log("移除《\(track.title)》")
    }

    func showInFinder(_ track: Track) {
        NSWorkspace.shared.activateFileViewerSelecting([
            LibraryLocation.mediaURL(for: track.fileName)
        ])
    }

    func artwork(for track: Track) async -> NSImage? {
        let key = track.id.uuidString as NSString
        if let cached = artworkCache.object(forKey: key) { return cached }

        let coverName = track.coverFileName
        let image = await Task.detached(priority: .utility) {
            Artwork.image(for: coverName)
        }.value
        artworkCache.setObject(image, forKey: key)
        return image
    }
}

enum SongSearch {
    static func isActive(_ query: String) -> Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static func filter(_ tracks: [Track], query: String) -> [Track] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return tracks }
        return tracks.filter { track in
            track.title.localizedCaseInsensitiveContains(trimmed)
                || track.artist.localizedCaseInsensitiveContains(trimmed)
                || track.album.localizedCaseInsensitiveContains(trimmed)
                || track.albumArtist.localizedCaseInsensitiveContains(trimmed)
        }
    }
}
