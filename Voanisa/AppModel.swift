import AppKit
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var tracks: [Track] = []
    @Published var selection: SidebarItem? = .songs
    @Published var searchText = ""
    @Published var repeatMode: RepeatMode = .off

    @Published var errorMessage: String?
    @Published var isShowingError = false

    @Published var deleteTarget: Track?

    let player = PlaybackEngine()
    let imports = ImportController()
    private let artworkCache = NSCache<NSString, NSImage>()

    init() {
        do {
            try LibraryLocation.ensureDirectories()
        } catch {
            Diagnostics.log("无法创建曲库目录：\(error.localizedDescription)")
        }
        tracks = LibraryStore.load()
        Diagnostics.markSession()
        Diagnostics.log("Rust core \(RustCore.version)")

        player.onFinished = { [weak self] in
            self?.advanceAfterFinish()
        }
        imports.onError = { [weak self] message in
            self?.presentError(message)
        }

        MediaKeys.install(
            onPrevious: { [weak self] in self?.playOffset(-1) },
            onNext: { [weak self] in self?.playOffset(1) },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() }
        )
    }

    var visibleTracks: [Track] {
        SongSearch.filter(tracks, query: searchText)
    }

    var currentTrack: Track? {
        guard let id = player.currentTrackID else { return nil }
        return tracks.first { $0.id == id }
    }

    // MARK: - Playback

    func play(_ track: Track) {
        do {
            try player.play(track: track)
        } catch {
            presentError(String(localized: "error.play") + "\n" + error.localizedDescription)
        }
    }

    func togglePlayPause() {
        if player.currentTrackID == nil {
            if let first = visibleTracks.first { play(first) }
        } else {
            player.togglePlayPause()
        }
    }

    func playOffset(_ offset: Int) {
        let list = visibleTracks
        guard !list.isEmpty else { return }

        guard let currentID = player.currentTrackID,
              let index = list.firstIndex(where: { $0.id == currentID }) else {
            if let first = list.first { play(first) }
            return
        }

        var target = index + offset
        if target < 0 {
            guard repeatMode == .all else { return }
            target = list.count - 1
        } else if target >= list.count {
            guard repeatMode == .all else { return }
            target = 0
        }
        play(list[target])
    }

    func cycleRepeatMode() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
        Diagnostics.log("循环模式 -> \(repeatMode.rawValue)")
    }

    private func advanceAfterFinish() {
        switch repeatMode {
        case .one:
            player.seek(to: 0)
            player.togglePlayPause()
        case .all, .off:
            playOffset(1)
        }
    }

    // MARK: - Library

    func reorder(_ newTracks: [Track]) {
        tracks = newTracks
        save()
    }

    func save() {
        do {
            try LibraryStore.save(tracks)
        } catch {
            presentError(error.localizedDescription)
        }
    }

    func requestDelete(_ track: Track) {
        deleteTarget = track
    }

    func confirmDelete() {
        guard let track = deleteTarget else { return }
        if player.currentTrackID == track.id {
            player.stop()
        }
        tracks.removeAll { $0.id == track.id }
        save()

        let audioURL = LibraryLocation.mediaURL(for: track.fileName)
        try? FileManager.default.trashItem(at: audioURL, resultingItemURL: nil)
        if let cover = track.coverFileName {
            try? FileManager.default.trashItem(
                at: LibraryLocation.coverURL(for: cover),
                resultingItemURL: nil
            )
        }
        artworkCache.removeObject(forKey: track.id.uuidString as NSString)
        Diagnostics.log("移除《\(track.title)》")
        deleteTarget = nil
    }

    func showInFinder(_ track: Track) {
        NSWorkspace.shared.activateFileViewerSelecting([LibraryLocation.mediaURL(for: track.fileName)])
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

    // MARK: - Import

    func applyImport(_ outcome: ImportOutcome) {
        tracks.append(contentsOf: outcome.tracks)
        save()
        imports.finish()

        if player.currentTrackID == nil, let first = outcome.tracks.first {
            play(first)
        }
        if !outcome.failures.isEmpty {
            presentError(outcome.failures.joined(separator: "\n"))
        }
        if outcome.skippedDuplicates > 0 {
            Diagnostics.log("导入完成：新增 \(outcome.tracks.count) 首，跳过重复 \(outcome.skippedDuplicates) 首")
        }
    }

    // MARK: - Errors

    func presentError(_ message: String) {
        errorMessage = message
        isShowingError = true
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
