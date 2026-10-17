import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .songs
    @Published var repeatMode: RepeatMode = .off

    @Published var errorMessage: String?
    @Published var isShowingError = false

    @Published var deleteTarget: Track?
    @Published var metadataTarget: Track?

    let player = PlaybackEngine()
    let imports = ImportController()
    let library = LibraryController()

    init() {
        Diagnostics.markSession()
        Diagnostics.log("Rust core \(RustCore.version)")

        player.onFinished = { [weak self] in
            self?.advanceAfterFinish()
        }
        imports.onError = { [weak self] message in
            self?.presentError(message, context: "import")
        }
        library.onError = { [weak self] message in
            self?.presentError(message, context: "library")
        }

        MediaKeys.install(
            onPrevious: { [weak self] in self?.playOffset(-1) },
            onNext: { [weak self] in self?.playOffset(1) },
            onTogglePlayPause: { [weak self] in self?.togglePlayPause() }
        )
    }

    var currentTrack: Track? {
        library.track(id: player.currentTrackID)
    }

    // MARK: - Playback

    func play(_ track: Track) {
        do {
            try player.play(track: track)
        } catch {
            presentError(
                String(localized: "error.play") + "\n" + error.localizedDescription,
                context: "playback"
            )
        }
    }

    func togglePlayPause() {
        if player.currentTrackID == nil {
            if let first = library.visibleTracks.first { play(first) }
        } else {
            player.togglePlayPause()
        }
    }

    func playOffset(_ offset: Int) {
        let list = library.visibleTracks
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

    func requestDelete(_ track: Track) {
        deleteTarget = track
    }

    func confirmDelete() {
        guard let track = deleteTarget else { return }
        if player.currentTrackID == track.id {
            player.stop()
        }
        library.remove(track)
        deleteTarget = nil
    }

    func requestMetadataEdit(_ track: Track) {
        metadataTarget = track
    }

    func saveMetadata(
        _ track: Track,
        edit: TrackMetadataEdit,
        cover: TrackCoverEdit
    ) {
        if let updated = library.updateMetadata(track, edit: edit, cover: cover) {
            player.refresh(track: updated)
        }
        metadataTarget = nil
    }

    // MARK: - Playlists

    @discardableResult
    func createPlaylist(name: String) -> Playlist? {
        library.createPlaylist(name: name)
    }

    func renamePlaylist(_ playlist: Playlist, to name: String) {
        library.renamePlaylist(playlist, to: name)
    }

    func deletePlaylist(_ playlist: Playlist) {
        if selection == .playlist(playlist.id) {
            selection = .songs
        }
        library.deletePlaylist(playlist)
    }

    func add(_ track: Track, to playlist: Playlist) {
        library.add(track, to: playlist.id)
    }

    func remove(_ track: Track, from playlist: Playlist) {
        library.remove(track, from: playlist.id)
    }

    // MARK: - Import

    func applyImport(_ outcome: ImportOutcome) {
        if !outcome.tracks.isEmpty {
            library.append(outcome.tracks)
        }

        if player.currentTrackID == nil, let first = outcome.tracks.first {
            play(first)
        }
        if outcome.cancelled {
            Diagnostics.log("导入已取消：新增 \(outcome.tracks.count) 首")
        }
        if outcome.skippedDuplicates > 0 {
            Diagnostics.log("导入完成：新增 \(outcome.tracks.count) 首，跳过重复 \(outcome.skippedDuplicates) 首")
        }
    }

    // MARK: - Errors

    func presentError(_ message: String, context: String = "app") {
        Diagnostics.error(message, context: context)
        errorMessage = message
        isShowingError = true
    }
}
