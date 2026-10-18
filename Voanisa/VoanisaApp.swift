import AppKit
import SwiftUI

@main
struct VoanisaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("menu.about") {
                    NSApplication.shared.orderFrontStandardAboutPanel(options: [
                        .applicationName: "Voanisa",
                        .applicationVersion: AppVersion.current,
                        .version: AppVersion.build,
                        .credits: NSAttributedString(
                            string: String(localized: "settings.about.description")
                                + "\n\n" + String(localized: "settings.about.copyright")
                        )
                    ])
                }
            }
            // Single-window tool: free ⌘N and put import on ⌘O.
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .newItem) {
                Button("menu.import") {
                    model.imports.presentPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            // Delete lives in the Edit menu as well as on the Delete key, so it
            // can be found without knowing about the context menu.
            CommandGroup(after: .pasteboard) {
                Divider()
                Button("common.remove") {
                    model.deleteSelectedTrack()
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(model.selectedTrackID == nil)
            }
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
