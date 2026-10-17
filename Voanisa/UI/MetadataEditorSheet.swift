import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MetadataEditorSheet: View {
    let track: Track
    let onSave: (TrackMetadataEdit, TrackCoverEdit) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    @State private var edit: TrackMetadataEdit
    @State private var coverJPEG: Data?
    @State private var coverEdit: TrackCoverEdit = .keep
    @State private var isCropping = false
    @State private var cropImage: CGImage?
    @State private var pendingOriginal: Data?
    @State private var didAttempt = false

    init(
        track: Track,
        onSave: @escaping (TrackMetadataEdit, TrackCoverEdit) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.track = track
        self.onSave = onSave
        self.onCancel = onCancel
        self.onError = onError
        _edit = State(initialValue: TrackMetadataEdit(track: track))
        _coverJPEG = State(initialValue: Self.loadCover(track))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    field("import.name", text: $edit.title)
                    field("import.artist", text: $edit.artist)
                    field("import.album", text: $edit.album)
                    field("import.albumArtist", text: $edit.albumArtist)

                    HStack(alignment: .top, spacing: 12) {
                        numberField("import.trackNumber", value: $edit.trackNumber)
                        numberField("import.discNumber", value: $edit.discNumber)
                    }

                    if didAttempt, !edit.isValid {
                        Text("metadata.title.required")
                            .font(.caption)
                            .foregroundColor(.red)
                    }

                    coverEditor
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 520, height: 640)
        .sheet(isPresented: $isCropping) {
            if let cropImage {
                CoverCropSheet(
                    image: cropImage,
                    onCancel: {
                        isCropping = false
                        pendingOriginal = nil
                    },
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
            Text("metadata.title")
                .font(.headline)
            Text(track.fileName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var coverEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("metadata.cover")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 16) {
                Group {
                    if let coverJPEG, let image = NSImage(data: coverJPEG) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.gray.opacity(0.22))
                            .overlay(
                                Image(systemName: "photo")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.secondary)
                            )
                    }
                }
                .frame(width: 160, height: 160)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 10) {
                    Button("metadata.chooseCover") {
                        chooseCover()
                    }
                    if coverJPEG != nil {
                        Button("metadata.removeCover") {
                            coverJPEG = nil
                            coverEdit = .remove
                        }
                        .foregroundStyle(.red)
                    }
                }

                Spacer()
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
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

            Button(action: save) {
                Text("metadata.save")
                    .foregroundColor(edit.isValid ? .blue : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                edit.isValid ? Color.blue : Color.secondary.opacity(0.4),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
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

    private func chooseCover() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "metadata.chooseCover")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = CoverRenderer.loadOrientedImage(url: url) else {
            onError(String(localized: "error.cover"))
            return
        }

        pendingOriginal = CoverRenderer.jpegData(image, quality: 0.95)
        cropImage = image
        isCropping = true
    }

    private func applyCrop(_ cropped: CGImage) {
        let resized = CoverRenderer.resizedSquare(cropped, side: 1024) ?? cropped
        guard let jpeg = CoverRenderer.jpegData(resized) else {
            onError(String(localized: "error.cover"))
            pendingOriginal = nil
            cropImage = nil
            return
        }

        coverJPEG = jpeg
        coverEdit = .replace(jpeg: jpeg, original: pendingOriginal)
        pendingOriginal = nil
        cropImage = nil
    }

    private func save() {
        didAttempt = true
        guard edit.isValid else { return }
        onSave(edit, coverEdit)
    }

    private static func loadCover(_ track: Track) -> Data? {
        guard let name = track.coverFileName else { return nil }
        return try? Data(contentsOf: LibraryLocation.coverURL(for: name))
    }
}
