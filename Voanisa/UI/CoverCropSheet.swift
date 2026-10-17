import SwiftUI

/// Square cover editor.
///
/// The image is shown in a fixed square viewport. The user pans and zooms, and
/// the same transform is converted back to pixel coordinates on confirm.
struct CoverCropSheet: View {
    let image: CGImage
    let onCancel: () -> Void
    let onConfirm: (CGImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStartOffset: CGSize = .zero
    @State private var isDragging = false
    @State private var viewSide: CGFloat = 380

    private let side: CGFloat = 380
    private let maxZoom: CGFloat = 8

    var body: some View {
        VStack(spacing: 16) {
            VStack(spacing: 4) {
                Text("crop.title")
                    .font(.headline)
                Text("crop.hint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                let currentSide = min(geometry.size.width, geometry.size.height)
                let baseScale = max(
                    currentSide / CGFloat(image.width),
                    currentSide / CGFloat(image.height)
                )
                let scale = baseScale * zoom
                let displayWidth = CGFloat(image.width) * scale
                let displayHeight = CGFloat(image.height) * scale

                ZStack {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: displayWidth, height: displayHeight)
                        .offset(offset)
                }
                .frame(width: currentSide, height: currentSide)
                .clipped()
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.85), lineWidth: 1)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            if !isDragging {
                                dragStartOffset = offset
                                isDragging = true
                            }
                            offset = clamped(
                                CGSize(
                                    width: dragStartOffset.width + value.translation.width,
                                    height: dragStartOffset.height + value.translation.height
                                ),
                                displayWidth: displayWidth,
                                displayHeight: displayHeight,
                                side: currentSide
                            )
                        }
                        .onEnded { _ in
                            isDragging = false
                        }
                )
                .onAppear { viewSide = currentSide }
                .onChange(of: currentSide) { _, newValue in viewSide = newValue }
            }
            .frame(width: side, height: side)

            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...maxZoom)
                    .tint(.red)
                    .frame(width: 220)
                    .onChange(of: zoom) { _, _ in
                        let base = max(
                            viewSide / CGFloat(image.width),
                            viewSide / CGFloat(image.height)
                        )
                        let scale = base * zoom
                        offset = clamped(
                            offset,
                            displayWidth: CGFloat(image.width) * scale,
                            displayHeight: CGFloat(image.height) * scale,
                            side: viewSide
                        )
                    }
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Spacer()

                Button(action: onCancel) {
                    Text("crop.cancel")
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.red, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button(action: confirm) {
                    Text("crop.confirm")
                        .foregroundColor(.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.blue, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func clamped(
        _ value: CGSize,
        displayWidth: CGFloat,
        displayHeight: CGFloat,
        side: CGFloat
    ) -> CGSize {
        let maxX = max(0, (displayWidth - side) / 2)
        let maxY = max(0, (displayHeight - side) / 2)
        return CGSize(
            width: min(max(value.width, -maxX), maxX),
            height: min(max(value.height, -maxY), maxY)
        )
    }

    private func confirm() {
        let baseScale = max(
            viewSide / CGFloat(image.width),
            viewSide / CGFloat(image.height)
        )
        let scale = baseScale * zoom
        let displayWidth = CGFloat(image.width) * scale
        let displayHeight = CGFloat(image.height) * scale
        let originX = (viewSide - displayWidth) / 2 + offset.width
        let originY = (viewSide - displayHeight) / 2 + offset.height
        let cropSide = viewSide / scale

        let x = min(max(0, -originX / scale), max(0, CGFloat(image.width) - cropSide))
        let y = min(max(0, -originY / scale), max(0, CGFloat(image.height) - cropSide))
        let rect = CGRect(x: x, y: y, width: cropSide, height: cropSide).integral

        guard let cropped = image.cropping(to: rect) else { return }
        onConfirm(cropped)
    }
}
