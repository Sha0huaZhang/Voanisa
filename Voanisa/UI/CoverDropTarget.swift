import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension View {
    /// Accepts an image dragged in from Finder or another app.
    ///
    /// Every cover path ends in a square JPEG, so the drop only decodes the
    /// dropped file and hands it to the same crop sheet the file picker uses;
    /// there is no second code path for dragged images.
    func coverDropTarget(
        isTargeted: Binding<Bool>,
        onImage: @escaping (CGImage) -> Void
    ) -> some View {
        modifier(CoverDropTarget(isTargeted: isTargeted, onImage: onImage))
    }
}

private struct CoverDropTarget: ViewModifier {
    @Binding var isTargeted: Bool
    let onImage: (CGImage) -> Void

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isTargeted ? Color.accentColor : Color.clear,
                        lineWidth: 3
                    )
            )
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                guard let provider = providers.first else { return false }

                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    let url: URL?
                    if let data = item as? Data {
                        url = URL(dataRepresentation: data, relativeTo: nil)
                    } else {
                        url = item as? URL
                    }
                    guard let url,
                          let image = CoverRenderer.loadOrientedImage(url: url) else {
                        return
                    }
                    DispatchQueue.main.async { onImage(image) }
                }
                return true
            }
    }
}
