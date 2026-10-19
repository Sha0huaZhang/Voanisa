import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var library: LibraryController
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var isConfirmingRestart = false
    @State private var isCheckingVersion = false
    @State private var versionOutcome: VersionCheck.Outcome?

    var body: some View {
        Form {
            Section("settings.language") {
                Picker("settings.language", selection: $appLanguageRawValue) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language.rawValue)
                    }
                }
                .labelsHidden()
                .onChange(of: appLanguageRawValue) { _, newValue in
                    (AppLanguage(rawValue: newValue) ?? .system).apply()
                    isConfirmingRestart = true
                }
            }

            Section("settings.library") {
                LabeledContent("settings.songCount") {
                    Text("\(library.tracks.count)")
                        .foregroundStyle(.secondary)
                }

                Text("settings.library.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("settings.library.export") {
                    exportLibrary()
                }
                .disabled(library.tracks.isEmpty)

                Text("settings.library.export.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("settings.version") {
                LabeledContent("settings.version.current") {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                HStack(spacing: 8) {
                    Button("settings.version.check", action: checkForUpdates)
                        .disabled(isCheckingVersion)

                    if isCheckingVersion {
                        ProgressView()
                            .controlSize(.small)
                        Text("settings.version.checking")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                versionStatus
            }
        }
        .formStyle(.grouped)
        .alert("settings.language.restart.title", isPresented: $isConfirmingRestart) {
            Button("common.later", role: .cancel) {}
            Button("common.restart", action: relaunch)
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("settings.language.restart.message")
        }
    }

    @ViewBuilder
    private var versionStatus: some View {
        switch versionOutcome {
        case .upToDate:
            Label("settings.version.upToDate", systemImage: "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)

        case .updateAvailable(let latest):
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(verbatim: VersionCheck.availableMessage(latest: latest))
                } icon: {
                    Image(systemName: "arrow.down.circle.fill")
                }
                .font(.callout)
                .fontWeight(.semibold)

                Text("settings.version.guide")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("settings.version.download") {
                    NSWorkspace.shared.open(UpdateChecker.downloadPage)
                }
            }

        case .failed:
            Text("settings.version.failed")
                .font(.callout)
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)

        case nil:
            EmptyView()
        }
    }

    private func checkForUpdates() {
        isCheckingVersion = true
        versionOutcome = nil
        Task {
            let tag = try? await UpdateChecker.latestTag()
            await MainActor.run {
                versionOutcome = VersionCheck.outcome(
                    current: AppVersion.current,
                    latestTag: tag
                )
                isCheckingVersion = false
            }
        }
    }

    private func exportLibrary() {
        let panel = NSSavePanel()
        panel.title = String(localized: "settings.library.export")
        panel.nameFieldStringValue = "library.json"
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }
        library.exportLibrary(to: url)
    }

    /// Launches a fresh instance and quits this one so the new AppleLanguages
    /// value is read from scratch.
    private func relaunch() {
        let url = Bundle.main.bundleURL
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
