import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var imports: ImportController
    @State private var isDropTargeted = false

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
                onImport: imports.presentPanel
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
                onCancel: imports.cancel,
                onError: model.presentError
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
                get: { model.deleteTarget != nil },
                set: { if !$0 { model.deleteTarget = nil } }
            ),
            presenting: model.deleteTarget
        ) { track in
            Button("common.remove.confirm.button", role: .destructive) {
                model.confirmDelete()
            }
            Button("common.cancel", role: .cancel) {
                model.deleteTarget = nil
            }
        } message: { track in
            Text(String(format: String(localized: "common.remove.confirm.message"), track.title))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
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
        case .playlists:
            ComingSoonView(
                systemImage: "music.note.list",
                title: "playlists.comingSoon.title",
                message: "playlists.comingSoon.hint"
            )
        case .albums:
            ComingSoonView(
                systemImage: "square.stack",
                title: "albums.comingSoon.title",
                message: "albums.comingSoon.hint"
            )
        }
    }

    @ViewBuilder
    private var preparingOverlay: some View {
        if imports.isPreparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("progress.preparing")
                    .font(.callout)
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
