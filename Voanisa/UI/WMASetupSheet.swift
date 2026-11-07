import AppKit
import SwiftUI

/// The install-time question about WMA support.
///
/// WMA cannot be decoded by macOS or by the portable core, so Voanisa asks once
/// where an ffmpeg already on this Mac came from, and copies it into its own
/// folder. Nothing is downloaded and nothing is shipped with the app.
struct WMASetupSheet: View {
    var onClose: () -> Void

    @State private var step: Step = .question
    @State private var choice: Choice = .tool(.homebrew)
    @State private var customPath = ""
    @State private var source: URL?
    @State private var message: String?
    /// An ffmpeg of unknown origin, offered by hand when the chosen tool has none.
    @State private var suggested: URL?
    @State private var copiedCommand: String?

    private enum Step: Equatable {
        case question
        case chooseTool(installed: Bool)
        case prebuilt
        case confirm
        case done
    }

    private enum Choice: Equatable {
        case tool(FFmpegTool)
        case other
        case prebuilt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 540)
        .onAppear {
            Diagnostics.log("打开 WMA 支持向导，已安装 = \(FFmpegLocation.isInstalled)")
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.tint)

            VStack(alignment: .leading, spacing: 4) {
                Text("wma.setup.title")
                    .font(.title3.weight(.semibold))
                Text("wma.setup.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .question:
            question

        case .chooseTool(let installed):
            chooseTool(installed: installed)

        case .prebuilt:
            prebuilt

        case .confirm:
            confirm

        case .done:
            done
        }
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("wma.setup.question")
                .font(.headline)

            Text("wma.setup.intro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button("wma.setup.answer.yes") {
                    message = nil
                    choice = .tool(.homebrew)
                    step = .chooseTool(installed: true)
                }
                .buttonStyle(.borderedProminent)

                Button("wma.setup.answer.no") {
                    message = nil
                    choice = .tool(.homebrew)
                    step = .chooseTool(installed: false)
                }
            }

            licenseNote
        }
    }

    private func chooseTool(installed: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(
                installed
                    ? LocalizedStringKey("wma.setup.whichInstalled")
                    : LocalizedStringKey("wma.setup.whichToInstall")
            )
                .font(.headline)

            VStack(spacing: 0) {
                ForEach(Array(choices(installed: installed).enumerated()), id: \.offset) { index, item in
                    choiceRow(item, number: index + 1)
                    if index < choices(installed: installed).count - 1 {
                        Divider().padding(.leading, 8)
                    }
                }
            }
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            if installed, choice == .other {
                customPathField
            }

            if !installed, case .tool(let tool) = choice, let command = tool.installCommand {
                commandBlock(command)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let suggested {
                // Never pick a different binary on the user's behalf: show what
                // was found and let them say yes.
                Button(
                    String(
                        format: String(localized: "wma.setup.useFound"),
                        DisplayPath.abbreviated(suggested)
                    )
                ) {
                    chooseFoundBinary(suggested)
                }
            }
        }
    }

    private var prebuilt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("wma.setup.prebuilt.title")
                .font(.headline)

            Text("wma.setup.prebuilt.intro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 16) {
                Text(verbatim: DisplayPath.abbreviated(FFmpegLocation.libraryDirectory))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                Button("wma.setup.reveal") {
                    revealLibraryFolder()
                }
            }
            .padding(10)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))

            Text("wma.setup.prebuilt.steps")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button("wma.setup.openDownload") {
                NSWorkspace.shared.open(URL(string: "https://ffmpeg.org/download.html")!)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            licenseNote
        }
    }

    private var confirm: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("wma.setup.confirm.title")
                .font(.headline)

            if let source {
                LabeledContent("wma.setup.confirm.source") {
                    Text(verbatim: DisplayPath.abbreviated(source))
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }

            LabeledContent("wma.setup.confirm.destination") {
                Text(verbatim: DisplayPath.abbreviated(FFmpegLocation.copyURL))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            if FFmpegLocation.isInstalled {
                Text("wma.setup.confirm.replace")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            licenseNote
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("wma.setup.done.title", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

            Text("wma.setup.done.message")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(verbatim: DisplayPath.abbreviated(FFmpegLocation.copyURL))
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    private var customPathField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wma.setup.other.prompt")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("wma.setup.other.placeholder", text: $customPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))

                Button("wma.setup.other.choose") {
                    chooseFile()
                }
            }
        }
    }

    private func commandBlock(_ command: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("wma.setup.command.intro")
                .font(.callout)

            HStack(spacing: 10) {
                Text(verbatim: command)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))

                Button(copiedCommand == command ? copyTitle.copied : copyTitle.copy) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copiedCommand = command
                    Diagnostics.log("已复制安装命令 \(command)")
                }
            }

            Text("wma.setup.command.after")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var licenseNote: some View {
        Text("wma.setup.license")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("wma.setup.later") {
                onClose()
            }

            Spacer(minLength: 0)

            if canGoBack {
                Button("wma.setup.back") {
                    message = nil
                    step = .question
                }
            }

            if let nextTitle {
                Button(nextTitle) {
                    advance()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }

    // MARK: - Choices

    private func choices(installed: Bool) -> [Choice] {
        if installed {
            return FFmpegTool.allCases.map(Choice.tool) + [.other]
        }
        return FFmpegTool.installingTools.map(Choice.tool) + [.prebuilt]
    }

    private func choiceRow(_ item: Choice, number: Int) -> some View {
        Button {
            message = nil
            copiedCommand = nil
            choice = item
        } label: {
            HStack(spacing: 10) {
                Image(systemName: choice == item ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(choice == item ? Color.accentColor : Color.secondary)

                Text(verbatim: "\(number).")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .trailing)

                title(for: item)
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// `FFmpegTool.title` is already localized, so it must not go through the
    /// key lookup again; the two list-only entries are keys.
    private func title(for item: Choice) -> Text {
        switch item {
        case .tool(let tool):
            return Text(verbatim: tool.title)
        case .other:
            return Text("wma.setup.other")
        case .prebuilt:
            return Text("wma.setup.prebuilt.choice")
        }
    }

    // MARK: - Footer state

    private var copyTitle: (copy: LocalizedStringKey, copied: LocalizedStringKey) {
        ("wma.setup.command.copy", "wma.setup.command.copied")
    }

    private var canGoBack: Bool {
        switch step {
        case .chooseTool, .prebuilt, .confirm: return true
        case .question, .done: return false
        }
    }

    private var nextTitle: LocalizedStringKey? {
        switch step {
        case .question, .done: return nil
        case .chooseTool(let installed): return installed ? "wma.setup.next" : "wma.setup.installedNext"
        case .prebuilt: return "wma.setup.next"
        case .confirm: return "wma.setup.copyAction"
        }
    }

    private func advance() {
        message = nil
        switch step {
        case .question, .done:
            break

        case .chooseTool(let installed):
            if choice == .prebuilt {
                step = .prebuilt
                return
            }
            guard let found = resolveSelection() else {
                message = installed
                    ? String(localized: "wma.setup.notFound")
                    : String(localized: "wma.setup.notInstalledYet")
                // Resolution failed, so anything found here came from another tool.
                suggested = FFmpegLocation.findAnywhere()
                return
            }
            suggested = nil
            source = found
            step = .confirm

        case .prebuilt:
            guard MacWaveConfiguration.isExecutable(FFmpegLocation.copyURL) else {
                message = String(localized: "wma.setup.prebuilt.missing")
                return
            }
            guard FFmpeg.runs(FFmpegLocation.copyURL) else {
                message = String(localized: "wma.setup.prebuilt.blocked")
                return
            }
            step = .done

        case .confirm:
            copyIntoVoanisa()
        }
    }

    private func resolveSelection() -> URL? {
        switch choice {
        case .tool(let tool):
            return FFmpegLocation.resolve(tool)
        case .other:
            return FFmpegLocation.resolve(path: customPath)
        case .prebuilt:
            return nil
        }
    }

    private func chooseFoundBinary(_ url: URL) {
        choice = .other
        customPath = url.path
        source = url
        message = nil
        suggested = nil
        Diagnostics.log("WMA 支持：采用找到的 ffmpeg \(url.path)")
        step = .confirm
    }

    private func copyIntoVoanisa() {
        guard let source else {
            message = String(localized: "wma.setup.notFound")
            return
        }
        guard FFmpeg.runs(source) else {
            message = String(localized: "wma.error.willNotRun")
            return
        }
        do {
            try FFmpegLocation.install(from: source)
            Diagnostics.log("WMA 支持：已复制 \(source.path) → \(FFmpegLocation.copyURL.path)")
            step = .done
        } catch {
            Diagnostics.error(error.localizedDescription, context: "wma.setup")
            message = error.localizedDescription
        }
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "wma.setup.other.choose")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customPath = url.path
    }

    private func revealLibraryFolder() {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: FFmpegLocation.libraryDirectory,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([FFmpegLocation.libraryDirectory])
    }
}
