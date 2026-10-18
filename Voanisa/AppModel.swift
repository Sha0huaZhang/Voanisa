import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .songs
    @Published var repeatMode: RepeatMode = .off

    @Published var errorMessage: String?
    @Published var isShowingError = false

    @Published var deleteTarget: Track?
    @Published var metadataTarget: Track?
    /// The row the user clicked most recently; Delete and the Edit menu act on it.
    @Published var selectedTrackID: UUID?

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

    var selectedTrack: Track? {
        library.track(id: selectedTrackID)
    }

    /// The list currently on screen. This is the source of truth for next/previous,
    /// matching Elysia's "the visible list is the playback order" rule.
    var activeScope: PlaybackScope {
        switch selection ?? .songs {
        case .playlist(let id):
            return .playlist(id)
        default:
            return .library
        }
    }

    var activeTracks: [Track] {
        switch activeScope {
        case .library:
            return library.tracks
        case .playlist(let id):
            guard let playlist = library.playlist(id: id) else { return [] }
            return library.tracks(in: playlist)
        }
    }

    // MARK: - Playback

    func play(_ track: Track) {
        if player.currentTrackID == track.id {
            player.togglePlayPause()
            return
        }

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
            if let first = activeTracks.first { play(first) }
        } else {
            player.togglePlayPause()
        }
    }

    func playOffset(_ offset: Int) {
        let list = activeTracks
        guard !list.isEmpty else { return }

        guard let currentID = player.currentTrackID else {
            if let first = list.first { play(first) }
            return
        }

        // Elysia's rule: if the playing song is not in the list currently shown,
        // there is no safe anchor. Do not jump to an arbitrary song.
        guard list.contains(where: { $0.id == currentID }) else {
            Diagnostics.log("切歌跳过：当前曲目不在当前列表（\(list.count) 首）")
            return
        }

        guard let targetID = PlaybackNavigation.targetID(
            currentID: currentID,
            trackIDs: list.map(\.id),
            offset: offset,
            repeatAll: repeatMode == .all
        ), let target = list.first(where: { $0.id == targetID }) else {
            return
        }
        play(target)
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

    /// Menu and keyboard entry point: acts on the row the user selected.
    func deleteSelectedTrack() {
        guard let track = selectedTrack else { return }
        requestDelete(track)
    }

    func confirmDelete() {
        guard let track = deleteTarget else { return }
        if player.currentTrackID == track.id {
            player.stop()
        }
        library.remove(track)
        if selectedTrackID == track.id {
            selectedTrackID = nil
        }
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

        // Importing never starts playback: the user picks what to hear.
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
