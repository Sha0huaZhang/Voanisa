import SwiftUI

/// One selectable line in a `SelectionSheet`.
struct SelectionRow: Identifiable {
    let id: UUID
    let title: String
    let subtitle: String
    let coverFileName: String?
    let systemImage: String
}

/// Shared picker sheet, modelled on Elysia's "new playlist" window: a title, an
/// optional name field, a search box, rows with a radio dot, and a footer that
/// shows how many lines are selected next to cancel/confirm.
///
/// The confirm button is deliberately never `.disabled`: SwiftUI dims a
/// disabled button's colour, which reads as "the feature is broken". Pressing it
/// without a selection instead turns on the hint above it.
struct SelectionSheet: View {
    let title: LocalizedStringKey
    let rows: [SelectionRow]
    /// Shows a name field when set, e.g. when creating a playlist.
    var namePlaceholder: LocalizedStringKey?
    var nameExists: (String) -> Bool = { _ in false }
    var initialSelection: Set<UUID> = []
    var allowsMultiple = true
    /// Create flows may start empty; delete flows must name their target.
    var requiresSelection = true
    let confirmTitle: LocalizedStringKey
    var confirmTint: Color = .blue
    /// Localized format with one `%d`, e.g. "已选 %d 首".
    var countFormat: String?
    var emptyHint: LocalizedStringKey?
    let onConfirm: (String, [UUID]) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var query = ""
    @State private var selected: Set<UUID> = []
    @State private var didAttempt = false

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDuplicate: Bool {
        !trimmedName.isEmpty && nameExists(trimmedName)
    }

    private var needsName: Bool {
        didAttempt && namePlaceholder != nil && trimmedName.isEmpty
    }

    private var visibleRows: [SelectionRow] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rows }
        return rows.filter { row in
            row.title.localizedCaseInsensitiveContains(trimmed)
                || row.subtitle.localizedCaseInsensitiveContains(trimmed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear { selected = initialSelection }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if let namePlaceholder {
                HStack(spacing: 8) {
                    Text("sidebar.playlistName")
                        .foregroundColor(.secondary)
                    TextField(namePlaceholder, text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                if isDuplicate {
                    Text("sidebar.duplicatePlaylist")
                        .font(.caption)
                        .foregroundColor(.red)
                } else if needsName {
                    Text("sidebar.nameRequired")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            searchField
        }
        .padding(16)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            TextField("search.placeholder", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onExitCommand { query = "" }

            if !query.isEmpty {
                Button {
                    query = ""
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
    }

    // MARK: Rows

    @ViewBuilder
    private var content: some View {
        if rows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("songs.empty.title").foregroundStyle(.secondary)
                Text("songs.empty.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visibleRows.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("songs.noMatch.title").foregroundStyle(.secondary)
                Text("songs.noMatch.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(visibleRows) { row in
                SelectionPickRow(
                    row: row,
                    isSelected: selected.contains(row.id),
                    onToggle: { toggle(row.id) }
                )
            }
            .listStyle(.plain)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let countFormat {
                Text(String(format: countFormat, selected.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if selected.isEmpty, let emptyHint, didAttempt, requiresSelection {
                Text(emptyHint)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(action: onCancel) {
                HStack(spacing: 4) {
                    Text("common.cancel")
                        .foregroundColor(.primary)
                    Text(verbatim: "Esc")
                        .foregroundColor(.secondary)
                    Text(verbatim: "或")
                        .foregroundColor(.secondary)
                    Text(verbatim: "⌘.")
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.primary.opacity(0.45), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Button(action: confirm) {
                Text(confirmTitle)
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(selected.isEmpty ? confirmTint.opacity(0.35) : confirmTint)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(16)
        // Esc and ⌘. are equivalent on macOS, but one button can only carry one
        // shortcut, so a zero-impact button holds the second one.
        .background(
            Button(action: onCancel) { EmptyView() }
                .keyboardShortcut(".", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        )
    }

    // MARK: Actions

    private func toggle(_ id: UUID) {
        if allowsMultiple {
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
        } else {
            selected = [id]
        }
    }

    private func confirm() {
        didAttempt = true
        if namePlaceholder != nil, trimmedName.isEmpty || isDuplicate {
            return
        }
        guard !requiresSelection || !selected.isEmpty else { return }
        let order = rows.map(\.id).filter(selected.contains)
        onConfirm(trimmedName, order)
    }
}

/// A picker line: artwork, title over subtitle, and a radio dot that turns red
/// with the artwork frame and the title when selected.
private struct SelectionPickRow: View {
    let row: SelectionRow
    let isSelected: Bool
    let onToggle: () -> Void

    @State private var artworkImage: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let artworkImage {
                    Image(nsImage: artworkImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: row.systemImage)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.gray.opacity(0.18))
                }
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isSelected ? Color.red : Color.clear, lineWidth: 2)
            )
            .task(id: row.coverFileName) {
                guard let cover = row.coverFileName else { return }
                let name = cover
                let image = await Task.detached(priority: .utility) {
                    Artwork.image(for: name)
                }.value
                artworkImage = image
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundColor(isSelected ? .red : .primary)
                    .lineLimit(1)
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .red : .secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}
