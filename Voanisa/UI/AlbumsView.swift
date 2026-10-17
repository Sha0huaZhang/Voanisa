import SwiftUI

struct AlbumsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var library: LibraryController

    @State private var selectedAlbumID: String?

    init(model: AppModel) {
        self.model = model
        _library = ObservedObject(wrappedValue: model.library)
    }

    private var albums: [AlbumGroup] {
        AlbumGrouping.groups(from: library.tracks)
    }

    private var selectedAlbum: AlbumGroup? {
        albums.first { $0.id == selectedAlbumID }
    }

    var body: some View {
        Group {
            if let selectedAlbum {
                AlbumDetailView(model: model, album: selectedAlbum) {
                    selectedAlbumID = nil
                }
            } else if albums.isEmpty {
                emptyState
            } else {
                grid
            }
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 160), spacing: 18)],
                spacing: 18
            ) {
                ForEach(albums) { album in
                    Button {
                        selectedAlbumID = album.id
                    } label: {
                        AlbumCard(album: album)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(20)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.stack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("albums.empty.title")
                .foregroundStyle(.secondary)
            Text("albums.empty.hint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct AlbumCard: View {
    let album: AlbumGroup

    @State private var artwork = DefaultArtwork.image

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(nsImage: artwork)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))

            Text(album.title)
                .font(.headline)
                .lineLimit(1)
            Text(album.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(
                String(
                    format: String(localized: "playlist.songCount"),
                    album.tracks.count
                )
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .task(id: album.representativeTrack?.coverFileName) {
            let coverName = album.representativeTrack?.coverFileName
            artwork = await Task.detached(priority: .utility) {
                Artwork.image(for: coverName)
            }.value
        }
    }
}

struct AlbumDetailView: View {
    @ObservedObject var model: AppModel
    let album: AlbumGroup
    let onBack: () -> Void

    @ObservedObject private var library: LibraryController
    @ObservedObject private var player: PlaybackEngine

    @State private var artwork = DefaultArtwork.image

    init(model: AppModel, album: AlbumGroup, onBack: @escaping () -> Void) {
        self.model = model
        self.album = album
        self.onBack = onBack
        _library = ObservedObject(wrappedValue: model.library)
        _player = ObservedObject(wrappedValue: model.player)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            List {
                ForEach(album.tracks) { track in
                    SongRowView(
                        song: track,
                        isPlaying: track.id == player.currentTrackID && player.isPlaying,
                        isDragging: false,
                        isReorderEnabled: false,
                        onPlay: { model.play(track) },
                        onEdit: { model.requestMetadataEdit(track) },
                        onShowInFinder: { library.showInFinder(track) },
                        onRemove: { model.requestDelete(track) },
                        playlists: library.playlists,
                        onAddToPlaylist: { model.add(track, to: $0) },
                        onRemoveFromPlaylist: nil,
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
        }
        .task(id: album.representativeTrack?.coverFileName) {
            let coverName = album.representativeTrack?.coverFileName
            artwork = await Task.detached(priority: .utility) {
                Artwork.image(for: coverName)
            }.value
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3)
            }
            .buttonStyle(.plain)
            .help("common.back")

            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(album.artist)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(
                    String(
                        format: String(localized: "playlist.songCount"),
                        album.tracks.count
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button("playlist.playAll") {
                if let first = album.tracks.first {
                    model.play(first)
                }
            }
        }
        .padding(20)
    }
}
