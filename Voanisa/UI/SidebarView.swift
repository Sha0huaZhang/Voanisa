import SwiftUI

struct SidebarView: View {
    @Binding var selection: SidebarItem?
    @Binding var searchText: String
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            searchField
            importButton
            List(selection: $selection) {
                Section("sidebar.library") {
                    ForEach([SidebarItem.songs, .playlists, .albums]) { item in
                        Label(item.title, systemImage: item.systemImage)
                            .tag(item)
                    }
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
