import SwiftUI

@main
struct VoanisaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
        }
        .commands {
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
