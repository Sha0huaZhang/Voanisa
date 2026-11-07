import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var imports: ImportController
    @State private var isDropTargeted = false
    /// Filled by the song picker, transferred once the sheet has dismissed so
    /// the two presentations do not collide in a single update.
    @State private var pendingSongDeleteIDs: [UUID] = []
    /// Playlist rows in the sidebar, refreshed by `SidebarView`; used to decide
    /// whether a dragged song was dropped on one of them.
    @State private var playlistFrames: [UUID: CGRect] = [:]
    /// Playlist row highlighted while a song is dragged over the sidebar.
    @State private var draggedOverPlaylist: UUID?
    @State private var didLogEmptyPlaylistFrames = false
    /// The floating row drawn above every column while a song is dragged.
    @State private var dragPreview: SongDragPreview?

    init(model: AppModel) {
        self.model = model
        _imports = ObservedObject(wrappedValue: model.imports)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $model.selection,
                searchText: Binding(
                    get: { model.library.searchText },
                    set: { model.library.searchText = $0 }
                ),
                library: model.library,
                onImport: imports.presentPanel,
                onRequestDeletePlaylist: { model.requestPlaylistDelete($0) },
                onPlaylistFrames: { playlistFrames = $0 },
                highlightedPlaylist: draggedOverPlaylist
            )
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 620)
        .overlay(alignment: .topLeading) { dragPreviewOverlay }
        .overlay(alignment: .topTrailing) { preparingOverlay }
        .overlay { dropOverlay }
        .sheet(isPresented: Binding(
            get: { imports.isShowing },
            set: { imports.isShowing = $0 }
        )) {
            ImportSheet(
                controller: imports,
                existingTracks: model.library.tracks,
                onApply: model.applyImport,
                onFinish: imports.finish,
                onCancel: imports.cancel,
                onError: { model.presentError($0, context: "import") }
            )
        }
        .sheet(item: $model.metadataTarget) { track in
            MetadataEditorSheet(
                track: track,
                onSave: { edit, cover in
                    model.saveMetadata(track, edit: edit, cover: cover)
                },
                onCancel: { model.metadataTarget = nil },
                onError: { model.presentError($0, context: "metadata") }
            )
        }
        .sheet(item: $model.coverTarget) { track in
            CoverChangeSheet(
                track: track,
                onSave: { cover in
                    model.saveCover(track, cover: cover)
                },
                onCancel: { model.coverTarget = nil },
                onError: { model.presentError($0, context: "metadata") }
            )
        }
        .sheet(item: $model.renameTarget) { track in
            RenameSheet(
                track: track,
                isDuplicate: { title in
                    model.hasDuplicateTitle(
                        title,
                        artist: track.displayArtist,
                        excluding: track.id
                    )
                },
                onSave: { model.rename(track, to: $0) },
                onCancel: { model.renameTarget = nil }
            )
        }
        .alert("error.title", isPresented: $model.isShowingError) {
            Button("common.gotIt") {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(isPresented: $model.isShowingWMASetup) {
            WMASetupSheet { model.isShowingWMASetup = false }
        }
        .confirmationDialog(
            "common.remove.confirm.title",
            isPresented: Binding(
                get: { !model.deleteTargets.isEmpty },
                set: { if !$0 { model.deleteTargets = [] } }
            ),
            presenting: model.deleteTargets.first
        ) { track in
            Button("common.remove.confirm.button", role: .destructive) {
                model.confirmDelete()
            }
            Button("common.cancel", role: .cancel) {
                model.deleteTargets = []
            }
        } message: { track in
            if model.deleteTargets.count > 1 {
                Text(
                    String(
                        format: String(localized: "common.remove.confirm.messageMany"),
                        model.deleteTargets.count
                    )
                )
            } else {
                Text(
                    String(
                        format: String(localized: "common.remove.confirm.message"),
                        track.title
                    )
                )
            }
        }
        .sheet(isPresented: $model.isPickingSongsToDelete, onDismiss: {
            guard !pendingSongDeleteIDs.isEmpty else { return }
            let ids = Set(pendingSongDeleteIDs)
            pendingSongDeleteIDs = []
            model.requestDelete(model.library.tracks.filter { ids.contains($0.id) })
        }) {
            SelectionSheet(
                title: "songs.delete.pick",
                rows: songPickerRows,
                confirmTitle: "common.deleteSong",
                confirmTint: .red,
                countFormat: String(localized: "picker.selectedSongs"),
                emptyHint: "songs.delete.pickHint",
                onConfirm: { _, ids in
                    pendingSongDeleteIDs = ids
                    model.isPickingSongsToDelete = false
                },
                onCancel: { model.isPickingSongsToDelete = false }
            )
        }
        .sheet(isPresented: $model.isPickingPlaylistToDelete) {
            SelectionSheet(
                title: "sidebar.deletePlaylist.pick",
                rows: model.library.playlists.map { playlist in
                    SelectionRow(
                        id: playlist.id,
                        title: playlist.name,
                        subtitle: String(
                            format: String(localized: "playlist.songCount"),
                            playlist.trackIDs.count
                        ),
                        coverFileName: nil,
                        systemImage: "music.note.list"
                    )
                },
                initialSelection: model.playlistDeleteSelection,
                allowsMultiple: false,
                confirmTitle: "sidebar.deletePlaylist.short",
                confirmTint: .red,
                emptyHint: "sidebar.deletePlaylist.pickHint",
                onConfirm: { _, ids in
                    model.isPickingPlaylistToDelete = false
                    guard let id = ids.first,
                          let playlist = model.library.playlist(id: id) else { return }
                    model.deletePlaylist(playlist)
                },
                onCancel: { model.isPickingPlaylistToDelete = false }
            )
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }

    private var songPickerRows: [SelectionRow] {
        model.library.tracks.map { track in
            SelectionRow(
                id: track.id,
                title: track.title,
                subtitle: track.displayArtist,
                coverFileName: track.coverFileName,
                systemImage: "music.note"
            )
        }
    }

    /// Leaves the song list in the hierarchy while another page is shown.
    ///
    /// SwiftUI tears a list down as soon as it leaves the switch, and coming back
    /// rebuilds it at the top. Reading and restoring the offset by hand never held
    /// up (the probe view gets replaced mid-scroll). Keeping the list alive but
    /// hidden, with the other page stacked on top, lets the system preserve the
    /// scroll position exactly.
    private var detail: some View {
        ZStack {
            songsPage
                .opacity(isShowingSongs ? 1 : 0)
                .allowsHitTesting(isShowingSongs)
                .accessibilityHidden(!isShowingSongs)

            if !isShowingSongs {
                // The song list has to stay alive for its scroll position, but it
                // is backed by an NSScrollView, and AppKit views keep taking mouse
                // events at opacity 0 — clicks on empty space in the page above
                // reached through and selected a row that was not on screen.
                EventBarrier()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                otherDetail
            }
        }
    }

    private var isShowingSongs: Bool {
        switch model.selection ?? .songs {
        case .songs: return true
        case .playlist, .about, .settings: return false
        }
    }

    private var songsPage: some View {
        VStack(spacing: 0) {
            PlayerControlBar(model: model)
            Divider()
            SongListView(
                model: model,
                playlistHitTest: playlistHitTest,
                onDropOnPlaylist: addToPlaylist,
                onDropTargetChange: { draggedOverPlaylist = $0 },
                onDragPreview: { dragPreview = $0 }
            )
        }
    }

    /// Draws the dragged row above the whole window, so it can leave the list
    /// and shrink while hovering the sidebar.
    @ViewBuilder
    private var dragPreviewOverlay: some View {
        if let preview = dragPreview,
           let track = model.library.track(id: preview.songID) {
            GeometryReader { proxy in
                let root = proxy.frame(in: .global)
                let overPlaylist = playlistHitTest(preview.pointer) != nil

                SongDragCard(song: track, artwork: preview.artwork)
                    .frame(width: 300, height: 48, alignment: .leading)
                    .scaleEffect(overPlaylist ? 0.62 : 1)
                    .opacity(overPlaylist ? 0.85 : 1)
                    .position(
                        x: preview.pointer.x - root.minX,
                        y: preview.pointer.y - root.minY
                    )
                    .animation(.easeOut(duration: 0.12), value: overPlaylist)
            }
            .allowsHitTesting(false)
        }
    }

    /// Which playlist row is under `point`, if the pointer is over the sidebar.
    private func playlistHitTest(_ point: CGPoint) -> UUID? {
        if playlistFrames.isEmpty, !didLogEmptyPlaylistFrames {
            didLogEmptyPlaylistFrames = true
            Diagnostics.log("拖动诊断：侧栏歌单 frame 为空，命中测试无从谈起")
        }

        // A row's reported frame is the label's tight box, so the gaps between
        // rows and the row padding fall outside every frame. Inside the sidebar
        // column, fall back to the vertically nearest row.
        if let exact = playlistFrames.first(where: { $0.value.contains(point) }) {
            return exact.key
        }
        guard let sidebarRight = playlistFrames.values.map(\.maxX).max(),
              point.x <= sidebarRight + 28 else {
            return nil
        }
        let nearest = playlistFrames.min { left, right in
            abs(left.value.midY - point.y) < abs(right.value.midY - point.y)
        }
        guard let nearest, abs(nearest.value.midY - point.y) <= 24 else { return nil }
        return nearest.key
    }

    private func addToPlaylist(_ track: Track, _ playlistID: UUID) {
        Diagnostics.log("拖动加入歌单：《\(track.title)》→ \(playlistID)")
        model.library.add(track, to: playlistID)
    }

    @ViewBuilder
    private var otherDetail: some View {
        switch model.selection ?? .songs {
        case .songs:
            EmptyView()
        case .about:
            AboutView()
        case .settings:
            SettingsView(library: model.library)
        case .playlist(let id):
            if let playlist = model.library.playlist(id: id) {
                PlaylistDetailView(
                    model: model,
                    playlist: playlist,
                    playlistHitTest: playlistHitTest,
                    onDropOnPlaylist: addToPlaylist,
                    onDropTargetChange: { draggedOverPlaylist = $0 },
                    onDragPreview: { dragPreview = $0 }
                )
            } else {
                Text("playlist.missing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder
    private var preparingOverlay: some View {
        if imports.isPreparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if imports.preparingTotal > 0 {
                    Text(
                        String(
                            format: String(localized: "progress.preparingCount"),
                            imports.preparingCount,
                            imports.preparingTotal
                        )
                    )
                    .font(.callout)
                    .monospacedDigit()
                } else {
                    Text("progress.preparing")
                        .font(.callout)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .padding(16)
        }
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .padding(10)
                Text("drop.hint")
                    .font(.headline)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(.regularMaterial, in: Capsule())
            }
            .allowsHitTesting(false)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let itemURL = item as? URL {
                    url = itemURL
                }
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            imports.importURLs(urls)
        }
        return true
    }
}

/// Swallows mouse events for a page that is kept alive but not visible.
///
/// SwiftUI's `allowsHitTesting(false)` does not reach AppKit views inside the
/// subtree: the song list's `NSScrollView` keeps handling clicks and selecting
/// rows at `opacity 0`, so clicking empty space on the playlist page used to
/// "reach through" and select whatever row sat under the pointer. This barrier
/// sits between the hidden page and the visible one and stops those events.
private struct EventBarrier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        BarrierView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class BarrierView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? {
            let local = superview.map { convert(point, from: $0) } ?? point
            return bounds.contains(local) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {}
        override func mouseUp(with event: NSEvent) {}
        override func rightMouseDown(with event: NSEvent) {}
        override func rightMouseUp(with event: NSEvent) {}
        override func otherMouseDown(with event: NSEvent) {}
        override func scrollWheel(with event: NSEvent) {}
    }
}
