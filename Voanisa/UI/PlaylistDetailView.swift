import SwiftUI

struct PlaylistDetailView: View {
    @ObservedObject var model: AppModel
    let playlist: Playlist

    @ObservedObject private var library: LibraryController
    @ObservedObject private var player: PlaybackEngine

    @State private var isRenaming = false
    @State private var renameName = ""
    @State private var isConfirmingDelete = false

    init(model: AppModel, playlist: Playlist) {
        self.model = model
        self.playlist = playlist
        _library = ObservedObject(wrappedValue: model.library)
        _player = ObservedObject(wrappedValue: model.player)
    }

    private var currentPlaylist: Playlist? {
        library.playlist(id: playlist.id)
    }

    private var tracks: [Track] {
        currentPlaylist.map { library.tracks(in: $0) } ?? []
    }

    var body: some View {
        Group {
            if let currentPlaylist {
                content(for: currentPlaylist)
            } else {
                Text("playlist.missing")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func content(for playlist: Playlist) -> some View {
        VStack(spacing: 0) {
            header(playlist)
            Divider()

            if tracks.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(tracks) { track in
                        SongRowView(
                            song: track,
                            isPlaying: track.id == player.currentTrackID && player.isPlaying,
                            isSelected: model.selectedTrackID == track.id,
                            isDragging: false,
                            isReorderEnabled: false,
                            onSelect: { model.selectedTrackID = track.id },
                            onPlay: { model.play(track) },
                            onEdit: { model.requestMetadataEdit(track) },
                            onShowInFinder: { library.showInFinder(track) },
                            onRemove: { model.requestDelete(track) },
                            playlists: [],
                            onAddToPlaylist: { _ in },
                            onRemoveFromPlaylist: {
                                model.remove(track, from: playlist)
                            },
                            onDragChanged: { _, _, _ in },
                            onDragEnded: { _, _ in }
                        )
                        .listRowInsets(
                            EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
                        )
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .onDeleteCommand { model.deleteSelectedTrack() }
            }
        }
        .alert("playlist.rename", isPresented: $isRenaming) {
            TextField("sidebar.playlistName", text: $renameName)
            Button("common.cancel", role: .cancel) {}
            Button("common.rename") {
                model.renamePlaylist(playlist, to: renameName)
            }
        }
        .confirmationDialog(
            "sidebar.deletePlaylist.confirm.title",
            isPresented: $isConfirmingDelete
        ) {
            Button("sidebar.deletePlaylist", role: .destructive) {
                model.deletePlaylist(playlist)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(
                String(
                    format: String(localized: "sidebar.deletePlaylist.confirm.message"),
                    playlist.name
                )
            )
        }
    }

    private func header(_ playlist: Playlist) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "music.note.list")
                .font(.system(size: 34))
                .foregroundStyle(.red)

            VStack(alignment: .leading, spacing: 3) {
                Text(playlist.name)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(
                    String(
                        format: String(localized: "playlist.songCount"),
                        tracks.count
                    )
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("playlist.playAll") {
                if let first = tracks.first {
                    model.play(first)
                }
            }
            .disabled(tracks.isEmpty)

            Menu {
                Button("playlist.rename") {
                    renameName = playlist.name
                    isRenaming = true
                }
                Button("sidebar.deletePlaylist", role: .destructive) {
                    isConfirmingDelete = true
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note.list")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("playlist.empty.title")
                .foregroundStyle(.secondary)
            Text("playlist.empty.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}
