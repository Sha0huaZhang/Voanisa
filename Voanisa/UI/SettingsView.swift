import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Section("settings.library") {
                LabeledContent("settings.songCount") {
                    Text("\(model.tracks.count)")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("settings.location") {
                    Text(LibraryLocation.rootURL.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Button("settings.openFolder", action: model.openLibraryFolder)

                Text("settings.library.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("settings.about") {
                LabeledContent("settings.version") {
                    Text(AppVersion.current)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text("settings.about.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
