import SwiftUI

/// The small “rename” dialog behind a song's context menu.
///
/// It only touches the title: everything else (artist, album, cover, file name,
/// hash) stays as it is, and `LibraryController.updateMetadata` still carries the
/// change into the file's tags. Duplicate titles are allowed — two songs by the
/// same artist can genuinely share one — so the dialog warns instead of refusing.
struct RenameSheet: View {
    let track: Track
    let isDuplicate: (String) -> Bool
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var name: String
    @FocusState private var isFocused: Bool

    init(
        track: Track,
        isDuplicate: @escaping (String) -> Bool,
        onSave: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.track = track
        self.isDuplicate = isDuplicate
        self.onSave = onSave
        self.onCancel = onCancel
        _name = State(initialValue: track.title)
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmed.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                TextField("rename.placeholder", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isFocused)
                    .onSubmit { save() }

                if !canSave {
                    Text("rename.empty")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if isDuplicate(trimmed) {
                    Text("rename.duplicate")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)

            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear { isFocused = true }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("rename.title")
                .font(.headline)
            Text(track.displayArtist.isEmpty ? track.title : track.displayArtist)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
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
                    .foregroundColor(canSave ? .blue : .secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                canSave ? Color.blue : Color.secondary.opacity(0.4),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
        }
        .padding(16)
    }

    private func save() {
        guard canSave else { return }
        onSave(trimmed)
    }
}
