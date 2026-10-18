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
        let panel = makeImportPanel()

        // The panel is presented as a sheet on the main window. `runModal()`
        // starts its own nested run loop, and when the window is not key the
        // panel can open *behind* it: the button then looks dead even though the
        // app is waiting. A window sheet is always in front of its parent.
        guard let window = NSApp.keyWindow
            ?? NSApp.mainWindow
            ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        else {
            Diagnostics.log("导入面板：找不到窗口，退回模态面板")
            if panel.runModal() == .OK {
                Diagnostics.log("导入面板：确认 \(panel.urls.count) 个文件/文件夹")
                importURLs(panel.urls)
            } else {
                Diagnostics.log("导入面板：已取消")
            }
            return
        }

        Diagnostics.log("导入面板：以窗口浮层打开")
        panel.beginSheetModal(for: window) { [weak self] response in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if response == .OK {
                    Diagnostics.log("导入面板：确认 \(panel.urls.count) 个文件/文件夹")
                    self.importURLs(panel.urls)
                } else {
                    Diagnostics.log("导入面板：已取消")
                }
            }
        }
    }

    private func makeImportPanel() -> NSOpenPanel {
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
        return panel
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        Diagnostics.log("开始准备 \(urls.count) 个文件")
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
                Diagnostics.log("准备完成：没有可导入的文件，弹出错误提示")
                onError?(String(localized: "import.noFiles"))
                return
            }
            Diagnostics.log("准备完成：\(candidates.count) 条候选，打开导入窗口")
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
        Diagnostics.log("导入窗口关闭")
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
        selection: Set<UUID>? = nil,
        onOutcome: @escaping (ImportOutcome) -> Void,
        onError: @escaping (String) -> Void
    ) {
        guard !isImporting else { return }

        let snapshot = selection.map { ids in
            candidates.filter { ids.contains($0.id) }
        } ?? candidates
        guard !snapshot.isEmpty else { return }

        isImporting = true
        isCancelling = false
        phase = .processing
        importedCount = 0
        totalCount = snapshot.count

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
