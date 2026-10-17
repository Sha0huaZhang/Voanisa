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
                    model.presentImportPanel()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .windowToolbarStyle(.unifiedCompact)
    }
}
