import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @ObservedObject var controller: ImportController
    let existingTracks: [Track]
    let onApply: (ImportOutcome) -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    @State private var selectedID: UUID?
    @State private var selectedForImport: Set<UUID> = []
    @State private var isCropping = false
    @State private var cropImage: CGImage?
    @State private var cropTargetID: UUID?

    @State private var didAttempt = false
    @State private var result: ImportOutcome?
    @State private var importedThisSession: [Track] = []

    private var candidates: [ImportCandidate] { controller.candidates }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return candidates.firstIndex { $0.id == selectedID }
    }

    private var selectedCandidate: ImportCandidate? {
        guard let index = selectedIndex else { return nil }
        return candidates[index]
    }

    private var importableCandidates: [ImportCandidate] {
        candidates.filter { candidate in
            candidate.error == nil
                && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var importableCount: Int {
        importableCandidates.count
    }

    private var pickedImportableCount: Int {
        importableCandidates.reduce(0) { count, candidate in
            selectedForImport.contains(candidate.id) ? count + 1 : count
        }
    }

    private var allImportablePicked: Bool {
        !importableCandidates.isEmpty && pickedImportableCount == importableCandidates.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let result {
                resultView(result)
            } else {
                HStack(spacing: 0) {
                    candidateList
                        .frame(width: 250)
                        .disabled(controller.isImporting)
                    Divider()
                    editor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .disabled(controller.isImporting)
                }
            }

            Divider()

            if result == nil {
                footer
            }
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if selectedID == nil {
                selectedID = candidates.first(where: { $0.error == nil })?.id ?? candidates.first?.id
            }
            selectedForImport = Set(importableCandidates.map(\.id))
        }
        .onChange(of: controller.candidates.map(\.id)) { _, _ in
            selectedForImport = Set(importableCandidates.map(\.id))
        }
        .sheet(isPresented: $isCropping) {
            if let cropImage {
                CoverCropSheet(
                    image: cropImage,
                    onCancel: { isCropping = false },
                    onConfirm: { cropped in
                        applyCrop(cropped)
                        isCropping = false
                    }
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("import.title")
                .font(.headline)
            Text("import.subtitle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private func resultView(_ outcome: ImportOutcome) -> some View {
        let failed = failedCandidates(for: outcome)
        let succeeded = outcome.failures.isEmpty && !outcome.cancelled
        return VStack(spacing: 16) {
            Spacer()

            Image(systemName: succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 42))
                .foregroundStyle(succeeded ? Color.green : Color.orange)

            Text(resultTitle(outcome))
                .font(.title3)
                .fontWeight(.semibold)

            Text(
                String(
                    format: String(localized: "import.result.summary"),
                    outcome.tracks.count,
                    outcome.skippedDuplicates,
                    outcome.failures.count
                )
            )
            .foregroundStyle(.secondary)

            if !outcome.failures.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(
                            Array(outcome.failures.enumerated()),
                            id: \.offset
                        ) { _, failure in
                            Text(failure)
                                .font(.callout)
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(12)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            Spacer()

            HStack(spacing: 12) {
                if !failed.isEmpty {
                    Button {
                        retry(failed)
                    } label: {
                        Text("import.retryFailed")
                            .foregroundColor(.blue)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 3)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(Color.blue, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }

                Button(action: onFinish) {
                    Text("common.done")
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.blue, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultTitle(_ outcome: ImportOutcome) -> LocalizedStringKey {
        outcome.cancelled ? "import.result.cancelled" : "import.result.title"
    }

    private func failedCandidates(for outcome: ImportOutcome) -> [ImportCandidate] {
        let ids = Set(outcome.failedCandidateIDs)
        return controller.candidates.filter { ids.contains($0.id) }
    }

    private func retry(_ failed: [ImportCandidate]) {
        controller.candidates = failed
        selectedID = failed.first(where: { $0.error == nil })?.id ?? failed.first?.id
        didAttempt = false
        result = nil
    }

    private var candidateList: some View {
        List(selection: $selectedID) {
            ForEach(candidates) { candidate in
                CandidateRow(
                    candidate: candidate,
                    isPicked: selectedForImport.contains(candidate.id),
                    onToggle: { toggleSelection(candidate) }
                )
                .tag(candidate.id)
            }
        }
        .listStyle(.plain)
    }

    private func toggleSelection(_ candidate: ImportCandidate) {
        guard candidate.error == nil else { return }
        if selectedForImport.contains(candidate.id) {
            selectedForImport.remove(candidate.id)
        } else {
            selectedForImport.insert(candidate.id)
        }
    }

    @ViewBuilder
    private var editor: some View {
        if let candidate = selectedCandidate, let index = selectedIndex {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = candidate.error {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    field("import.name", text: binding(\.title, fallback: ""))
                    field("import.artist", text: binding(\.artist, fallback: ""))
                    field("import.album", text: binding(\.album, fallback: ""))
                    field("import.albumArtist", text: binding(\.albumArtist, fallback: ""))

                    HStack(alignment: .top, spacing: 12) {
                        numberField(
                            "import.trackNumber",
                            value: binding(\.trackNumber, fallback: nil)
                        )
                        numberField(
                            "import.discNumber",
                            value: binding(\.discNumber, fallback: nil)
                        )
                    }

                    if didAttempt,
                       candidate.error == nil,
                       candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("import.title.required")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    Text(candidate.probe.formatDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    coverEditor(index: index, candidate: candidate)
                }
                .padding(20)
            }
        } else {
            Text("import.selectFile")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func field(_ title: LocalizedStringKey, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(title, text: text)
                .textFieldStyle(.roundedBorder)
        }
    }

    private func numberField(_ title: LocalizedStringKey, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(
                title,
                text: Binding(
                    get: { value.wrappedValue.map(String.init) ?? "" },
                    set: { text in
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty {
                            value.wrappedValue = nil
                        } else if let number = Int(trimmed) {
                            value.wrappedValue = number
                        }
                    }
                )
            )
            .textFieldStyle(.roundedBorder)
        }
    }

    private func coverEditor(index: Int, candidate: ImportCandidate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("import.cover")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let data = candidate.coverJPEG, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(nsImage: DefaultArtwork.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 150, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Button("import.chooseCover") {
                        chooseCover(for: candidate)
                    }
                    if candidate.coverJPEG != nil {
                        Button("import.removeCover") {
                            controller.candidates[index].coverJPEG = nil
                        }
                        .foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Toggle("import.skipDuplicates", isOn: $controller.skipDuplicates)
                .toggleStyle(.checkbox)
                .disabled(controller.isImporting)

            Button(allImportablePicked ? "import.selectNone" : "import.selectAll") {
                if allImportablePicked {
                    selectedForImport.removeAll()
                } else {
                    selectedForImport = Set(importableCandidates.map(\.id))
                }
            }
            .buttonStyle(.link)
            .disabled(controller.isImporting || importableCandidates.isEmpty)

            Text(
                String(
                    format: String(localized: "import.selectedCount"),
                    pickedImportableCount,
                    importableCount
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()

            if controller.isImporting {
                ProgressView(
                    value: Double(controller.importedCount),
                    total: Double(max(controller.totalCount, 1))
                )
                .controlSize(.small)
                .frame(width: 120)

                if controller.isSaving {
                    Text("import.saving")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    Text(
                        String(
                            format: String(localized: "import.progress"),
                            controller.importedCount,
                            controller.totalCount
                        )
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }

            Spacer()

            Button(action: cancelAction) {
                Text(cancelTitle)
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(controller.isCancelling || controller.isSaving)

            Button(action: performImport) {
                Text(importButtonTitle)
                    .foregroundColor(canImport ? .blue : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                canImport ? Color.blue : Color.secondary.opacity(0.4),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canImport)
        }
        .padding(16)
    }

    private var canImport: Bool {
        !controller.isImporting && pickedImportableCount > 0
    }

    private var cancelTitle: LocalizedStringKey {
        if controller.isCancelling {
            return "import.cancelling"
        }
        return controller.isImporting ? "import.cancelImport" : "common.cancel"
    }

    private var importButtonTitle: LocalizedStringKey {
        controller.isImporting ? "import.importing" : "import.confirm"
    }

    private func cancelAction() {
        if controller.isImporting {
            controller.cancelImport()
        } else {
            onCancel()
        }
    }

    private func binding<T>(
        _ keyPath: WritableKeyPath<ImportCandidate, T>,
        fallback: T
    ) -> Binding<T> {
        Binding(
            get: {
                guard let index = selectedIndex, controller.candidates.indices.contains(index) else {
                    return fallback
                }
                return controller.candidates[index][keyPath: keyPath]
            },
            set: { newValue in
                guard let index = selectedIndex, controller.candidates.indices.contains(index) else {
                    return
                }
                controller.candidates[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func chooseCover(for candidate: ImportCandidate) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "import.chooseCover")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CoverRenderer.loadOrientedImage(url: url) else {
            onError(String(localized: "error.cover"))
            return
        }

        let original = CoverRenderer.jpegData(image, quality: 0.95)
        if let index = controller.candidates.firstIndex(where: { $0.id == candidate.id }) {
            controller.candidates[index].originalCoverData = original
            controller.candidates[index].originalCoverExtension = "jpg"
        }

        cropTargetID = candidate.id
        cropImage = image
        isCropping = true
    }

    private func applyCrop(_ cropped: CGImage) {
        guard let target = cropTargetID,
              let index = controller.candidates.firstIndex(where: { $0.id == target }) else {
            return
        }
        let resized = CoverRenderer.resizedSquare(cropped, side: 1024) ?? cropped
        controller.candidates[index].coverJPEG = CoverRenderer.jpegData(resized)
        cropTargetID = nil
        cropImage = nil
    }

    private func performImport() {
        didAttempt = true
        guard canImport else { return }

        controller.startImport(
            existing: existingTracks + importedThisSession,
            selection: selectedForImport,
            onOutcome: handleOutcome,
            onError: onError
        )
    }

    private func handleOutcome(_ outcome: ImportOutcome) {
        importedThisSession.append(contentsOf: outcome.tracks)
        onApply(outcome)

        if outcome.failures.isEmpty,
           !outcome.cancelled,
           outcome.skippedDuplicates == 0 {
            onFinish()
        } else {
            result = outcome
        }
    }
}

private struct CandidateRow: View {
    let candidate: ImportCandidate
    let isPicked: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onToggle) {
                Image(systemName: isPicked ? "circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(
                        candidate.error != nil
                            ? Color.secondary.opacity(0.35)
                            : (isPicked ? Color.red : Color.secondary.opacity(0.7))
                    )
            }
            .buttonStyle(.plain)
            .disabled(candidate.error != nil)

            Image(systemName: candidate.error == nil ? "music.note" : "exclamationmark.triangle")
                .foregroundStyle(candidate.error == nil ? Color.secondary : Color.red)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                    .font(.body)
                    .lineLimit(1)
                Text(candidate.sourceURL.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(candidate.error ?? candidate.probe.formatDescription)
                    .font(.caption2)
                    .foregroundStyle(candidate.error == nil ? Color.secondary : Color.red)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
    }
}
