import AppKit
import Foundation
import UniformTypeIdentifiers

/// Opens the system image picker for a cover.
///
/// Every cover field lives inside one of our sheets, and AppKit allows a window
/// to carry only one sheet at a time: `runModal()` blocks the app, and a second
/// `beginSheetModal`/`fileImporter` queues behind the sheet that is already
/// attached — both look like a frozen button. A modeless panel floats above the
/// sheet instead, and its completion handler runs on the main queue.
enum CoverPicker {
    /// `begin` does not retain the panel for the whole session; without this the
    /// panel can be deallocated the moment the picker starts.
    private static var activePanel: NSOpenPanel?

    static func present(
        onPick: @escaping (CGImage) -> Void,
        onError: @escaping (String) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "metadata.chooseCover")
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.level = .floating

        activePanel = panel
        Diagnostics.log("选择封面：打开图片选择器")

        panel.begin { response in
            activePanel = nil

            guard response == .OK, let url = panel.url else {
                Diagnostics.log("选择封面：已取消")
                return
            }
            guard let image = CoverRenderer.loadOrientedImage(url: url) else {
                Diagnostics.log("选择封面：无法解码 \(url.lastPathComponent)")
                onError(String(localized: "error.cover"))
                return
            }

            Diagnostics.log("选择封面：\(url.lastPathComponent)")
            onPick(image)
        }
    }
}
