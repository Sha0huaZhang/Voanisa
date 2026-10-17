import AppKit
import Foundation
import UniformTypeIdentifiers

/// Owns the import session: the file panel, the candidate list and the
/// preparing/visible state. AppModel applies the finished outcome to the
/// library so importing and library mutation stay separate.
@MainActor
final class ImportController: ObservableObject {
    @Published var candidates: [ImportCandidate] = []
    @Published var isShowing = false
    @Published var isPreparing = false

    var onError: ((String) -> Void)?

    func presentPanel() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "import.panel.title")
        panel.message = String(localized: "import.panel.message")
        panel.prompt = String(localized: "import.panel.prompt")
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false

        var types: [UTType] = [.audio, .movie, .folder]
        for ext in ["mp3", "m4a", "m4b", "aac", "flac", "wav", "aiff", "aif", "caf", "mp4", "mov", "m4v"] {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        panel.allowedContentTypes = types

        if panel.runModal() == .OK {
            importURLs(panel.urls)
        }
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        isPreparing = true
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                await ImportService.prepare(urls: urls)
            }.value

            isPreparing = false
            guard !candidates.isEmpty else {
                onError?(String(localized: "import.noFiles"))
                return
            }
            self.candidates = candidates
            isShowing = true
        }
    }

    func cancel() {
        isShowing = false
        candidates = []
    }

    func finish() {
        isShowing = false
        candidates = []
    }

    func commit(existing: [Track]) async throws -> ImportOutcome {
        try await ImportService.commit(candidates: candidates, existing: existing)
    }
}
