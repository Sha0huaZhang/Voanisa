import AppKit
import Foundation

/// Owns the local library: tracks, search text, persistence, file trash and
/// artwork cache. Playback and import orchestration stay in AppModel.
@MainActor
final class LibraryController: ObservableObject {
    @Published private(set) var tracks: [Track] = []
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
            try LibraryStore.save(tracks)
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.save")
            onError?(error.localizedDescription)
        }
    }

    func exportLibrary(to url: URL) {
        do {
            try LibraryStore.exportJSON(tracks, to: url)
            Diagnostics.log("Exported \(tracks.count) tracks to \(url.path)")
        } catch {
            Diagnostics.error(error.localizedDescription, context: "library.export")
            onError?(error.localizedDescription)
        }
    }

    func remove(_ track: Track) {
        tracks.removeAll { $0.id == track.id }
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
        guard let coverName = track.coverFileName else { return nil }

        let url = LibraryLocation.coverURL(for: coverName)
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        guard let data, let image = NSImage(data: data) else { return nil }
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
        }
    }
}
