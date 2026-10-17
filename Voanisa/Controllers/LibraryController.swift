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
