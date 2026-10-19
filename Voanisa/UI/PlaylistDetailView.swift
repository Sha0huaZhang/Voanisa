import SwiftUI

struct PlaylistDetailView: View {
    @ObservedObject var model: AppModel
    let playlist: Playlist

    @ObservedObject private var library: LibraryController
    @ObservedObject private var player: PlaybackEngine

    @State private var isRenaming = false
    @State private var renameName = ""

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
                            isDragging: false,
                            isReorderEnabled: false,
                            onSelect: { model.selectedTrackID = track.id },
                            onPlay: { model.play(track) },
                            onEdit: { model.requestMetadataEdit(track) },
                            onRename: { model.requestRename(track) },
                            onChangeCover: { model.requestCoverChange(track) },
                            onShowInFinder: { library.showInFinder(track) },
                            onRemove: { model.requestDelete(track) },
                            playlists: library.playlists,
                            onTogglePlaylist: { model.toggle(track, in: $0) },
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
    }

    private func header(_ playlist: Playlist) -> some View {
        HStack(spacing: 14) {
            PlaylistHeaderArtwork(coverFileName: tracks.first?.coverFileName)

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

            Button {
                model.requestPlaylistDelete(playlist)
            } label: {
                HStack(spacing: 6) {
                    Text("sidebar.deletePlaylist.short")
                    Text(verbatim: "⌘D")
                        .foregroundColor(Color.red.opacity(0.55))
                }
                .foregroundColor(.red)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.red, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut("d", modifiers: .command)

            Menu {
                Button("playlist.rename") {
                    renameName = playlist.name
                    isRenaming = true
                }
                Button("sidebar.deletePlaylist.short", role: .destructive) {
                    model.requestPlaylistDelete(playlist)
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

/// The playlist's own artwork: its first song's cover, as Elysia does.
///
/// Falling back to the list icon while the cover loads (or when the playlist is
/// empty) keeps the header from resizing as songs come and go.
private struct PlaylistHeaderArtwork: View {
    let coverFileName: String?

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "music.note.list")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.gray.opacity(0.15))
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: coverFileName) {
            guard let coverFileName else {
                image = nil
                return
            }
            image = await Task.detached(priority: .utility) {
                Artwork.image(for: coverFileName)
            }.value
        }
    }
}
