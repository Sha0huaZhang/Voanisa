import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var searchText: String
    @ObservedObject var library: LibraryController
    let onImport: () -> Void

    @State private var isCreatingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var deletingPlaylist: Playlist?

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
                            .tag(SidebarItem.playlist(playlist.id))
                            .contextMenu {
                                Button("sidebar.deletePlaylist", role: .destructive) {
                                    deletingPlaylist = playlist
                                }
                            }
                    }

                    Button {
                        newPlaylistName = ""
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
        }
        .alert("sidebar.newPlaylist", isPresented: $isCreatingPlaylist) {
            TextField("sidebar.playlistName", text: $newPlaylistName)
            Button("common.cancel", role: .cancel) {}
            Button("common.create") {
                if let playlist = library.createPlaylist(name: newPlaylistName) {
                    selection = .playlist(playlist.id)
                }
            }
        }
        .confirmationDialog(
            "sidebar.deletePlaylist.confirm.title",
            isPresented: Binding(
                get: { deletingPlaylist != nil },
                set: { if !$0 { deletingPlaylist = nil } }
            ),
            presenting: deletingPlaylist
        ) { playlist in
            Button("sidebar.deletePlaylist", role: .destructive) {
                library.deletePlaylist(playlist)
                if selection == .playlist(playlist.id) {
                    selection = .songs
                }
                deletingPlaylist = nil
            }
            Button("common.cancel", role: .cancel) {
                deletingPlaylist = nil
            }
        } message: { playlist in
            Text(
                String(
                    format: String(localized: "sidebar.deletePlaylist.confirm.message"),
                    playlist.name
                )
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
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.blue, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
