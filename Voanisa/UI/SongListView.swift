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
    /// Drives the automatic scrolling while a row is dragged near an edge.
    @State private var scroller = ListAutoScroller()

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
        VStack(spacing: 0) {
            deleteBar

            GeometryReader { container in
                ZStack(alignment: .topLeading) {
                    List {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                            SongRowView(
                                song: song,
                                isPlaying: song.id == player.currentTrackID && player.isPlaying,
                                isDragging: draggingID == song.id,
                                isReorderEnabled: !isSearching,
                                onSelect: { model.selectedTrackID = song.id },
                                onPlay: { model.play(song) },
                                onEdit: { model.requestMetadataEdit(song) },
                                onRename: { model.requestRename(song) },
                                onChangeCover: { model.requestCoverChange(song) },
                                onShowInFinder: { library.showInFinder(song) },
                                onRemove: { model.requestDelete(song) },
                                playlists: library.playlists,
                                onTogglePlaylist: { model.toggle(song, in: $0) },
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
                                    scroller.update(
                                        pointerY: pointerY,
                                        visible: container.frame(in: .global)
                                    )
                                },
                                onDragEnded: { pointerY, startY in
                                    scroller.stop()
                                    finishDrag(
                                        of: song,
                                        index: index,
                                        translation: pointerY - startY
                                    )
                                }
                            )
                            .listRowInsets(
                                EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
                            )
                            .listRowSeparator(.hidden)
                            // Rows live inside the list's NSScrollView, so this is
                            // where the scroller can find it.
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
    }

    /// Visible counterpart to the row context menu and the Delete key. Elysia can
    /// live without one because it only reads the Apple Music library, while
    /// Voanisa owns the files and has to make removing them findable.
    ///
    /// It stays red on purpose: a disabled button is dimmed to grey, which looks
    /// like a broken feature. Without a selected row it opens the picker instead.
    private var deleteBar: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)

            Button(action: model.requestDeleteFromToolbar) {
                HStack(spacing: 6) {
                    Text("common.deleteSong")
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
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

struct RowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Scrolls the song list while a row is dragged into the top or bottom edge.
///
/// `DragGesture` only reports mouse movement, so holding a row against the edge
/// would otherwise never reach songs further away — the user had to drop, scroll
/// and drag again. A timer nudges the list's clip view instead.
final class ListAutoScroller {
    /// Height of the hot zone at each end, in points.
    private let edgeZone: CGFloat = 56
    /// Points per second at the very edge, scaled by how deep the pointer is.
    private let maxSpeed: CGFloat = 900

    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var speed: CGFloat = 0

    func attach(_ scrollView: NSScrollView?) {
        self.scrollView = scrollView
    }

    /// `pointerY` and `visible` are in the global coordinate space.
    func update(pointerY: CGFloat, visible: CGRect) {
        guard visible.height > edgeZone * 2 else {
            stop()
            return
        }

        let topDepth = (visible.minY + edgeZone - pointerY) / edgeZone
        let bottomDepth = (pointerY - (visible.maxY - edgeZone)) / edgeZone

        if topDepth > 0 {
            speed = -maxSpeed * min(1, topDepth)
        } else if bottomDepth > 0 {
            speed = maxSpeed * min(1, bottomDepth)
        } else {
            stop()
            return
        }

        startIfNeeded()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        speed = 0
    }

    private func startIfNeeded() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            self?.step()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func step() {
        guard let scrollView, speed != 0 else {
            stop()
            return
        }

        let clip = scrollView.contentView
        let documentHeight = scrollView.documentView?.frame.height ?? 0
        let maxOrigin = max(0, documentHeight - clip.bounds.height)
        var origin = clip.bounds.origin
        origin.y = min(max(0, origin.y + speed / 60), maxOrigin)

        guard origin.y != clip.bounds.origin.y else { return }
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Reports the `NSScrollView` a SwiftUI view ended up inside.
struct ScrollViewFinder: NSViewRepresentable {
    let onResolve: (NSScrollView?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { onResolve(view.enclosingScrollView) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(nsView.enclosingScrollView) }
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
    var onSelect: () -> Void = {}
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onRename: () -> Void
    let onChangeCover: () -> Void
    let onShowInFinder: () -> Void
    let onRemove: (() -> Void)?
    let playlists: [Playlist]
    let onTogglePlaylist: (Playlist) -> Void
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
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("common.play", action: onPlay)
            Button("common.rename", action: onRename)
            Button("common.editMetadata", action: onEdit)
            Button("common.changeCover", action: onChangeCover)

            if !playlists.isEmpty {
                Menu("common.addToPlaylist") {
                    // Toggles keep the menu open while the user ticks more than
                    // one playlist; each tick adds or removes this song.
                    ForEach(playlists) { playlist in
                        Toggle(
                            playlist.name,
                            isOn: Binding(
                                get: { playlist.trackIDs.contains(song.id) },
                                set: { _ in onTogglePlaylist(playlist) }
                            )
                        )
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
