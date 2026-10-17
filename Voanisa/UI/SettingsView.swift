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

                Text("settings.library.hint")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }
}
