import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ImportSheet: View {
    @ObservedObject var controller: ImportController
    let existingTracks: [Track]
    let onApply: (ImportOutcome) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    @State private var selectedID: UUID?
    @State private var isCropping = false
    @State private var cropImage: CGImage?
    @State private var cropTargetID: UUID?

    @State private var isImporting = false
    @State private var didAttempt = false

    private var candidates: [ImportCandidate] { controller.candidates }

    private var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return candidates.firstIndex { $0.id == selectedID }
    }

    private var selectedCandidate: ImportCandidate? {
        guard let index = selectedIndex else { return nil }
        return candidates[index]
    }

    private var importableCount: Int {
        candidates.filter { candidate in
            candidate.error == nil
                && !candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                candidateList
                    .frame(width: 250)
                Divider()
                editor
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 760, height: 560)
        .onAppear {
            if selectedID == nil {
                selectedID = candidates.first(where: { $0.error == nil })?.id ?? candidates.first?.id
            }
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

    private var candidateList: some View {
        List(selection: $selectedID) {
            ForEach(candidates) { candidate in
                CandidateRow(candidate: candidate)
                    .tag(candidate.id)
            }
        }
        .listStyle(.plain)
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
            Text(String(format: String(localized: "import.count"), importableCount))
                .font(.callout)
                .foregroundStyle(.secondary)

            if isImporting {
                ProgressView().controlSize(.small)
                Text("import.importing")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                Text("common.cancel")
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

            Button(action: performImport) {
                Text("import.confirm")
                    .foregroundColor(importableCount > 0 ? .blue : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(importableCount > 0 ? Color.blue : Color.secondary.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
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
        guard !isImporting, importableCount > 0 else { return }

        isImporting = true
        Task {
            do {
                let outcome = try await controller.commit(existing: existingTracks)
                await MainActor.run {
                    isImporting = false
                    onApply(outcome)
                }
            } catch {
                await MainActor.run {
                    isImporting = false
                    onError(error.localizedDescription)
                }
            }
        }
    }
}

private struct CandidateRow: View {
    let candidate: ImportCandidate

    var body: some View {
        HStack(spacing: 10) {
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
