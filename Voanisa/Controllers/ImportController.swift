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
    @Published private(set) var preparingCount = 0
    @Published private(set) var preparingTotal = 0
    @Published var skipDuplicates = true
    @Published private(set) var isImporting = false
    @Published private(set) var phase: ImportPhase?
    @Published private(set) var importedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var isCancelling = false

    /// True while the copied files are being written into the library.
    var isSaving: Bool { phase == .saving }

    private var importTask: Task<Void, Never>?

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
        preparingCount = 0
        preparingTotal = 0

        let report: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in
                self?.preparingCount = done
                self?.preparingTotal = total
            }
        }

        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                await ImportService.prepare(urls: urls, onProgress: report)
            }.value

            isPreparing = false
            preparingCount = 0
            preparingTotal = 0
            guard !candidates.isEmpty else {
                onError?(String(localized: "import.noFiles"))
                return
            }
            self.candidates = candidates
            isShowing = true
        }
    }

    func cancel() {
        if isImporting {
            cancelImport()
            return
        }
        finish()
    }

    func finish() {
        importTask?.cancel()
        importTask = nil
        isShowing = false
        isImporting = false
        isCancelling = false
        phase = nil
        importedCount = 0
        totalCount = 0
        candidates = []
    }

    func startImport(
        existing: [Track],
        onOutcome: @escaping (ImportOutcome) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard !isImporting else { return }

        isImporting = true
        isCancelling = false
        phase = .processing
        importedCount = 0
        totalCount = candidates.count

        let snapshot = candidates
        let shouldSkipDuplicates = skipDuplicates

        importTask = Task { [weak self] in
            do {
                let outcome = try await ImportService.commit(
                    candidates: snapshot,
                    existing: existing,
                    skipDuplicates: shouldSkipDuplicates,
                    onPhase: { phase in
                        Task { @MainActor [weak self] in
                            self?.phase = phase
                        }
                    },
                    onProgress: { done, total in
                        Task { @MainActor [weak self] in
                            self?.importedCount = done
                            self?.totalCount = total
                        }
                    }
                )

                await MainActor.run {
                    self?.finishImport()
                    onOutcome(outcome)
                }
            } catch {
                await MainActor.run {
                    self?.finishImport()
                    onError(error.localizedDescription)
                }
            }
        }
    }

    func cancelImport() {
        guard isImporting else { return }
        isCancelling = true
        importTask?.cancel()
    }

    private func finishImport() {
        importTask = nil
        isImporting = false
        isCancelling = false
        phase = nil
    }
}
