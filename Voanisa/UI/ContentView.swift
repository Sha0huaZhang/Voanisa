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
                onRequestDeletePlaylist: { model.requestPlaylistDelete($0) }
            )
            .navigationSplitViewColumnWidth(min: 170, ideal: 195, max: 240)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 860, minHeight: 620)
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
        .alert("error.title", isPresented: $model.isShowingError) {
            Button("common.gotIt") {}
        } message: {
            Text(model.errorMessage ?? "")
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

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .songs {
        case .songs:
            VStack(spacing: 0) {
                PlayerControlBar(model: model)
                Divider()
                SongListView(model: model)
            }
        case .about:
            AboutView()
        case .settings:
            SettingsView(library: model.library)
        case .playlist(let id):
            if let playlist = model.library.playlist(id: id) {
                PlaylistDetailView(model: model, playlist: playlist)
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
