import AppKit
import SwiftUI

struct SongListView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var player: PlaybackEngine
    @ObservedObject private var library: LibraryController

    @State private var draggingID: UUID?
    @State private var dragGrabOffsetY: CGFloat?
    @State private var dragPointerY: CGFloat?
    @State private var draggedArtwork: NSImage?
    @State private var rowFrames: [UUID: CGRect] = [:]

    private var songs: [Track] { library.visibleTracks }
    private var isSearching: Bool { SongSearch.isActive(library.searchText) }

    init(model: AppModel) {
        self.model = model
        _player = ObservedObject(wrappedValue: model.player)
        _library = ObservedObject(wrappedValue: model.library)
    }

    var body: some View {
        Group {
            if library.tracks.isEmpty {
                emptyState(
                    systemImage: "music.note.list",
                    title: "songs.empty.title",
                    hint: "songs.empty.hint"
                )
            } else if songs.isEmpty, isSearching {
                emptyState(
                    systemImage: "magnifyingglass",
                    title: "songs.noMatch.title",
                    hint: "songs.noMatch.hint"
                )
            } else {
                songList
            }
        }
    }

    private var songList: some View {
        GeometryReader { container in
            ZStack(alignment: .topLeading) {
                List {
                    ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                        SongRowView(
                            song: song,
                            isPlaying: song.id == player.currentTrackID && player.isPlaying,
                            isDragging: draggingID == song.id,
                            isReorderEnabled: !isSearching,
                            onPlay: { model.play(song) },
                            onEdit: { model.requestMetadataEdit(song) },
                            onShowInFinder: { library.showInFinder(song) },
                            onRemove: { model.requestDelete(song) },
                            playlists: library.playlists,
                            onAddToPlaylist: { model.add(song, to: $0) },
                            onRemoveFromPlaylist: nil,
                            onDragChanged: { pointerY, startY, artwork in
                                if draggingID != song.id {
                                    draggingID = song.id
                                    draggedArtwork = artwork
                                    dragGrabOffsetY = SongReorder.grabOffset(
                                        pointerStartY: startY,
                                        rowMinY: rowFrames[song.id]?.minY ?? startY
                                    )
                                }
                                dragPointerY = pointerY
                            },
                            onDragEnded: { pointerY, startY in
                                finishDrag(of: song, index: index, translation: pointerY - startY)
                            }
                        )
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .onPreferenceChange(RowFrameKey.self) { rowFrames = $0 }

                if let id = draggingID,
                   let frame = rowFrames[id],
                   let song = songs.first(where: { $0.id == id }),
                   let pointerY = dragPointerY,
                   let grabOffset = dragGrabOffsetY {
                    SongDragCard(song: song, artwork: draggedArtwork)
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

    private func targetSlot(for translation: CGFloat, frame: CGRect, index: Int) -> Int {
        let centreY = frame.midY + translation
        let centres = songs.indices.map { frame.midY + CGFloat($0 - index) * frame.height }
        return SongReorder.slot(forDraggedCentreY: centreY, rowCentres: centres)
    }

    private func finishDrag(of song: Track, index: Int, translation: CGFloat) {
        defer {
            draggingID = nil
            dragGrabOffsetY = nil
            dragPointerY = nil
            draggedArtwork = nil
        }

        guard let frame = rowFrames[song.id] else { return }
        let slot = targetSlot(for: translation, frame: frame, index: index)
        let reordered = SongReorder.moving(song.id, toSlot: slot, in: songs)
        guard reordered != songs else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            library.reorder(reordered)
        }
    }

    private func emptyState(systemImage: String, title: LocalizedStringKey, hint: LocalizedStringKey) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).foregroundStyle(.secondary)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

private struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct SongDragCard: View {
    let song: Track
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            artworkView(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(.semibold)
                Text(song.displayArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
    }

    @ViewBuilder
    private func artworkView(size: CGFloat) -> some View {
        Group {
            if let artwork {
                Image(nsImage: artwork)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: DefaultArtwork.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct ReorderDragModifier: ViewModifier {
    let enabled: Bool
    let onChanged: (CGFloat, CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { onChanged($0.location.y, $0.startLocation.y) }
                    .onEnded { onEnded($0.location.y, $0.startLocation.y) }
            )
        } else {
            content
        }
    }
}

struct SongRowView: View {
    let song: Track
    let isPlaying: Bool
    let isDragging: Bool
    let isReorderEnabled: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onShowInFinder: () -> Void
    let onRemove: (() -> Void)?
    let playlists: [Playlist]
    let onAddToPlaylist: (Playlist) -> Void
    let onRemoveFromPlaylist: (() -> Void)?
    let onDragChanged: (CGFloat, CGFloat, NSImage?) -> Void
    let onDragEnded: (CGFloat, CGFloat) -> Void

    @State private var isHovering = false
    @State private var artworkImage: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artworkImage {
                    Image(nsImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(nsImage: DefaultArtwork.image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isPlaying ? Color.red : Color.clear, lineWidth: 2)
            )
            .task(id: song.coverFileName) {
                await loadArtwork()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(song.title)
                    .font(.body)
                    .fontWeight(isPlaying ? .bold : .regular)
                    .foregroundColor(isPlaying ? .red : .primary)
                Text(song.displayArtist)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if isHovering, !isDragging {
                Button(action: onPlay) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: RowFrameKey.self,
                    value: [song.id: geo.frame(in: .global)]
                )
            }
        )
        .opacity(isDragging ? 0.25 : 1)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .onTapGesture(count: 2) {
            onPlay()
        }
        .contextMenu {
            Button("common.play", action: onPlay)
            Button("common.editMetadata", action: onEdit)

            if !playlists.isEmpty {
                Menu("common.addToPlaylist") {
                    ForEach(playlists) { playlist in
                        Button(playlist.name) {
                            onAddToPlaylist(playlist)
                        }
                    }
                }
            }

            Button("common.showInFinder", action: onShowInFinder)

            if let onRemoveFromPlaylist {
                Divider()
                Button("playlist.removeTrack", role: .destructive, action: onRemoveFromPlaylist)
            }

            if let onRemove {
                Divider()
                Button("common.remove", role: .destructive, action: onRemove)
            }
        }
        .modifier(
            ReorderDragModifier(
                enabled: isReorderEnabled,
                onChanged: { onDragChanged($0, $1, artworkImage) },
                onEnded: onDragEnded
            )
        )
    }

    private func loadArtwork() async {
        let coverName = song.coverFileName
        artworkImage = await Task.detached(priority: .utility) {
            Artwork.image(for: coverName)
        }.value
    }
}

enum SongReorder {
    /// Moves `draggedID` into `slot`, where slots are the gaps between songs:
    /// slot 0 sits above the first song and slot `songs.count` below the last.
    static func moving(_ draggedID: UUID, toSlot slot: Int, in songs: [Track]) -> [Track] {
        guard let from = songs.firstIndex(where: { $0.id == draggedID }) else { return songs }

        var result = songs
        let dragged = result.remove(at: from)
        let clamped = max(0, min(slot, songs.count))
        let adjusted = clamped > from ? clamped - 1 : clamped
        result.insert(dragged, at: max(0, min(adjusted, result.count)))
        return result
    }

    static func slot(forDraggedCentreY y: CGFloat, rowCentres: [CGFloat]) -> Int {
        rowCentres.filter { $0 < y }.count
    }

    static func grabOffset(pointerStartY: CGFloat, rowMinY: CGFloat) -> CGFloat {
        pointerStartY - rowMinY
    }

    static func dragCardTop(pointerY: CGFloat, grabOffsetY: CGFloat, containerMinY: CGFloat) -> CGFloat {
        pointerY - grabOffsetY - containerMinY
    }
}
