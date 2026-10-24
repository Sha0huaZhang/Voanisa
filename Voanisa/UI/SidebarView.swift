import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var searchText: String
    @ObservedObject var library: LibraryController
    let onImport: () -> Void
    let onRequestDeletePlaylist: (Playlist) -> Void
    /// Where each playlist row sits on screen, so a dragged song can be dropped
    /// on it.
    var onPlaylistFrames: ([UUID: CGRect]) -> Void = { _ in }

    @State private var isCreatingPlaylist = false

    var body: some View {
        VStack(spacing: 0) {
            searchField
            importButton
            List(selection: $selection) {
                Section("sidebar.library") {
                    ForEach([SidebarItem.songs]) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }

                Section("sidebar.playlists") {
                    ForEach(library.playlists) { playlist in
                        Label(playlist.name, systemImage: "music.note.list")
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .tag(SidebarItem.playlist(playlist.id))
                            .background(
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: PlaylistRowFrameKey.self,
                                        value: [playlist.id: geometry.frame(in: .global)]
                                    )
                                }
                            )
                            .contextMenu {
                                Button("sidebar.deletePlaylist.short", role: .destructive) {
                                    onRequestDeletePlaylist(playlist)
                                }
                            }
                    }

                    Button {
                        isCreatingPlaylist = true
                    } label: {
                        Label("sidebar.newPlaylist", systemImage: "plus")
                    }
                    .buttonStyle(.plain)
                }

                Section {
                    ForEach([SidebarItem.settings, .about]) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .onPreferenceChange(PlaylistRowFrameKey.self) { frames in
                onPlaylistFrames(frames)
            }
        }
        .sheet(isPresented: $isCreatingPlaylist) {
            SelectionSheet(
                title: "sidebar.newPlaylist",
                rows: library.tracks.map { track in
                    SelectionRow(
                        id: track.id,
                        title: track.title,
                        subtitle: track.displayArtist,
                        coverFileName: track.coverFileName,
                        systemImage: "music.note"
                    )
                },
                namePlaceholder: "sidebar.playlistName.placeholder",
                nameExists: { name in
                    library.playlists.contains {
                        $0.name.caseInsensitiveCompare(name) == .orderedSame
                    }
                },
                requiresSelection: false,
                confirmTitle: "common.create",
                confirmTint: .blue,
                countFormat: String(localized: "picker.selectedSongs"),
                onConfirm: { name, trackIDs in
                    isCreatingPlaylist = false
                    if let playlist = library.createPlaylist(name: name, trackIDs: trackIDs) {
                        selection = .playlist(playlist.id)
                    }
                },
                onCancel: { isCreatingPlaylist = false }
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("search.placeholder", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { searchText = "" }

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("search.clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var importButton: some View {
        Button(action: onImport) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                Text("sidebar.import")
                    .font(.system(size: 12))
            }
            .foregroundStyle(.blue)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            // The frame alone does not make the blank part of the strip
            // clickable: a plain button only reacts inside its content shape.
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.blue, lineWidth: 1)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}


/// Global frames of the playlist rows, used as drop targets while a song is
/// being dragged.
struct PlaylistRowFrameKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
