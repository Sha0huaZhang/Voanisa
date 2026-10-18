import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The sheet behind the row's “更换封面” menu item.
///
/// It deliberately carries only the cover: the metadata fields live in
/// `MetadataEditorSheet`, and someone who right-clicked “更换封面” does not want
/// to walk past five text fields to reach the picture.
struct CoverChangeSheet: View {
    let track: Track
    let onSave: (TrackCoverEdit) -> Void
    let onCancel: () -> Void
    let onError: (String) -> Void

    @State private var coverJPEG: Data?
    @State private var coverEdit: TrackCoverEdit = .keep
    @State private var isCropping = false
    @State private var cropImage: CGImage?
    @State private var pendingOriginal: Data?
    @State private var isDropTargeted = false

    init(
        track: Track,
        onSave: @escaping (TrackCoverEdit) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        self.track = track
        self.onSave = onSave
        self.onCancel = onCancel
        self.onError = onError
        _coverJPEG = State(initialValue: Self.loadCover(track))
    }

    var body: some View {
        Group {
            if isCropping, let cropImage {
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
                .padding(20)
            } else {
                content
            }
        }
        .frame(width: 380, height: 440)
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(spacing: 16) {
                thumbnail

                HStack(spacing: 12) {
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

                Text("cover.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("cover.title")
                .font(.headline)
            Text(track.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var thumbnail: some View {
        Group {
            if let coverJPEG, let image = NSImage(data: coverJPEG) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(nsImage: DefaultArtwork.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 220, height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .coverDropTarget(isTargeted: $isDropTargeted) { image in
            beginCrop(image)
        }
        .help(Text("cover.hint"))
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

            Button {
                onSave(coverEdit)
            } label: {
                Text("metadata.save")
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
        .padding(16)
    }

    private func chooseCover() {
        CoverPicker.present(
            onPick: { image in beginCrop(image) },
            onError: { message in onError(message) }
        )
    }

    private func beginCrop(_ image: CGImage) {
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

    private static func loadCover(_ track: Track) -> Data? {
        guard let name = track.coverFileName else { return nil }
        return try? Data(contentsOf: LibraryLocation.coverURL(for: name))
    }
}
