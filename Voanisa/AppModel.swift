import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .songs
    @Published var repeatMode: RepeatMode = .off

    @Published var errorMessage: String?
    @Published var isShowingError = false
    /// Shown once per version: WMA cannot be decoded, and users find that out by
    /// importing a folder full of it and seeing every row rejected.
    @Published var isShowingWMANotice = false

    @Published var deleteTargets: [Track] = []
    @Published var metadataTarget: Track?
    /// The song whose cover is being replaced from the row's context menu.
    @Published var coverTarget: Track?
    /// Shows the "choose songs to delete" picker when the toolbar button is
    /// pressed without a selected row (Elysia's behaviour).
    @Published var isPickingSongsToDelete = false
    /// Shows the "choose a playlist to delete" picker.
    @Published var isPickingPlaylistToDelete = false
    @Published var playlistDeleteSelection: Set<UUID> = []
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

        runDebugImportIfRequested()
        presentWMANoticeIfNeeded()
    }

    /// WMA is out of scope: macOS cannot decode it and the portable core has no
    /// ASF demuxer. Say so once per version — first install and every update —
    /// instead of letting an entire album arrive as “unsupported”.
    private func presentWMANoticeIfNeeded() {
        let key = "wmaNotice.version"
        let seen = UserDefaults.standard.string(forKey: key)
        guard seen != AppVersion.current else { return }

        UserDefaults.standard.set(AppVersion.current, forKey: key)
        isShowingWMANotice = true
        Diagnostics.log("提示 WMA 不受支持（版本 \(AppVersion.current)）")
    }

    /// `open -a Voanisa --args --import-test <path>` opens the import sheet for
    /// that file without going through the open panel. Used to check sheet
    /// presentation while developing; it prepares candidates only and never
    /// writes to the library.
    private func runDebugImportIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--import-test"),
              arguments.count > flag + 1 else { return }
        let path = arguments[flag + 1]
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Diagnostics.log("调试：触发导入 \(path)")
            self?.imports.importURLs([URL(fileURLWithPath: path)])
        }
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
        requestDelete([track])
    }

    func requestDelete(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        deleteTargets = tracks
    }

    /// Menu and keyboard entry point: acts on the row the user selected.
    func deleteSelectedTrack() {
        guard let track = selectedTrack else { return }
        requestDelete(track)
    }

    /// Toolbar entry point: an explicit selection wins, otherwise the picker
    /// opens so the user names the target himself.
    func requestDeleteFromToolbar() {
        if let track = selectedTrack {
            requestDelete(track)
        } else {
            isPickingSongsToDelete = true
        }
    }

    func confirmDelete() {
        let targets = deleteTargets
        deleteTargets = []
        for track in targets {
            if player.currentTrackID == track.id {
                player.stop()
            }
            if selectedTrackID == track.id {
                selectedTrackID = nil
            }
            library.remove(track)
        }
    }

    func requestMetadataEdit(_ track: Track) {
        metadataTarget = track
    }

    /// “更换封面” acts on the cover alone, so it skips the metadata sheet.
    func requestCoverChange(_ track: Track) {
        coverTarget = track
    }

    func saveCover(_ track: Track, cover: TrackCoverEdit) {
        if let updated = library.updateMetadata(
            track,
            edit: TrackMetadataEdit(track: track),
            cover: cover
        ) {
            player.refresh(track: updated)
        }
        coverTarget = nil
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

    /// Opens the playlist picker, pre-selecting the playlist the user was in.
    func requestPlaylistDelete(_ playlist: Playlist?) {
        playlistDeleteSelection = playlist.map { [$0.id] } ?? []
        isPickingPlaylistToDelete = true
    }

    func add(_ track: Track, to playlist: Playlist) {
        library.add(track, to: playlist.id)
    }

    /// The row menu ticks playlists on and off instead of adding to one.
    func toggle(_ track: Track, in playlist: Playlist) {
        if playlist.trackIDs.contains(track.id) {
            remove(track, from: playlist)
        } else {
            add(track, to: playlist)
        }
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
