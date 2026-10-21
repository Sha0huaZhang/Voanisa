import SwiftUI

struct PlaylistDetailView: View {
    @ObservedObject var model: AppModel
    let playlist: Playlist

    @ObservedObject private var library: LibraryController
    @ObservedObject private var player: PlaybackEngine

    @State private var isRenaming = false
    @State private var renameName = ""

    // Dragging state, mirroring the song list: the row itself follows the
    // pointer as a floating card, and the list scrolls when it nears an edge.
    @State private var draggingID: UUID?
    @State private var dragGrabOffsetY: CGFloat?
    @State private var dragPointerY: CGFloat?
    @State private var draggedArtwork: NSImage?
    @State private var rowFrames: [UUID: CGRect] = [:]
    @State private var scroller = ListAutoScroller()

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
                GeometryReader { container in
                    ZStack(alignment: .topLeading) {
                        List {
                            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                                SongRowView(
                                    song: track,
                                    isPlaying: track.id == player.currentTrackID && player.isPlaying,
                                    isDragging: draggingID == track.id,
                                    isReorderEnabled: true,
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
                                    onDragChanged: { pointerY, startY, artwork in
                                        if draggingID != track.id {
                                            draggingID = track.id
                                            draggedArtwork = artwork
                                            dragGrabOffsetY = SongReorder.grabOffset(
                                                pointerStartY: startY,
                                                rowMinY: rowFrames[track.id]?.minY ?? startY
                                            )
                                        }
                                        dragPointerY = pointerY
                                        scroller.update(
                                            pointerY: pointerY,
                                            visible: container.frame(in: .global)
                                        )
                                    },
                                    onDragEnded: { pointerY, startY in
                                        scroller.stop()
                                        finishDrag(
                                            of: track,
                                            index: index,
                                            translation: pointerY - startY
                                        )
                                    }
                                )
                                .listRowInsets(
                                    EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
                                )
                                .listRowSeparator(.hidden)
                                .background(ScrollViewFinder { scrollView in
                                    scroller.attach(scrollView)
                                })
                            }
                        }
                        .listStyle(.plain)
                        .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }
                        .onDeleteCommand { model.deleteSelectedTrack() }

                        if let id = draggingID,
                           let frame = rowFrames[id],
                           let track = tracks.first(where: { $0.id == id }),
                           let pointerY = dragPointerY,
                           let grabOffset = dragGrabOffsetY {
                            SongDragCard(song: track, artwork: draggedArtwork)
                                .frame(width: frame.width, height: frame.height)
                                .offset(y: SongReorder.dragCardTop(
                                    pointerY: pointerY,
                                    grabOffsetY: grabOffset,
                                    containerMinY: container.frame(in: .global).minY
                                ))
                                .allowsHitTesting(false)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .alert("playlist.rename", isPresented: $isRenaming) {
            TextField("sidebar.playlistName", text: $renameName)
                .onChange(of: renameName) { _, newValue in
                    if newValue.count > LibraryLimits.playlistName {
                        renameName = String(newValue.prefix(LibraryLimits.playlistName))
                    }
                }
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
                    .lineLimit(1)
                    .truncationMode(.tail)
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

            transportControls
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

    /// Same four buttons as the player bar: previous, play/pause, next, repeat.
    /// Next/previous already follow whatever list is on screen, so inside a
    /// playlist they step through that playlist.
    private var transportControls: some View {
        HStack(spacing: 20) {
            Button(action: { model.playOffset(-1) }) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .help("player.previous")

            Button(action: model.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .help("player.playPause")

            Button(action: { model.playOffset(1) }) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .help("player.next")

            Button(action: model.cycleRepeatMode) {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundColor(model.repeatMode == .off ? .primary : .red)
            }
            .buttonStyle(.plain)
            .help("player.repeat")
        }
        .font(.title3)
    }

    private func targetSlot(for translation: CGFloat, frame: CGRect, index: Int) -> Int {
        let centreY = frame.midY + translation
        let centres = tracks.indices.map { frame.midY + CGFloat($0 - index) * frame.height }
        return SongReorder.slot(forDraggedCentreY: centreY, rowCentres: centres)
    }

    private func finishDrag(of track: Track, index: Int, translation: CGFloat) {
        defer {
            draggingID = nil
            dragGrabOffsetY = nil
            dragPointerY = nil
            draggedArtwork = nil
        }

        guard let frame = rowFrames[track.id] else { return }
        let slot = targetSlot(for: translation, frame: frame, index: index)
        let reordered = SongReorder.moving(track.id, toSlot: slot, in: tracks)
        guard reordered != tracks else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            library.reorder(reordered, in: playlist.id)
        }
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
