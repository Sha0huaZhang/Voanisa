import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var library: LibraryController
    @AppStorage("appLanguage") private var appLanguageRawValue = AppLanguage.system.rawValue
    @State private var isConfirmingRestart = false

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
