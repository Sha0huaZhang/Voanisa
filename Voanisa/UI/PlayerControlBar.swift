import AppKit
import SwiftUI

struct PlayerControlBar: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var player: PlaybackEngine
    @ObservedObject private var library: LibraryController

    @State private var isDraggingPosition = false
    @State private var dragPosition: Double = 0
    @State private var isDraggingVolume = false
    @State private var dragVolume: Double = 0
    @State private var artwork: NSImage?

    init(model: AppModel) {
        self.model = model
        _player = ObservedObject(wrappedValue: model.player)
        _library = ObservedObject(wrappedValue: model.library)
    }

    private var currentTrack: Track? {
        library.track(id: player.currentTrackID)
    }

    var body: some View {
        HStack(spacing: 0) {
            transportControls
                .frame(width: 190, alignment: .leading)

            nowPlaying
                .frame(maxWidth: 400)

            volumeControls
                .frame(width: 190, alignment: .trailing)
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
        .onChange(of: player.currentTrackID) { _, _ in
            // Never let a drag from the previous song decide the new song's
            // progress display. This is the same correspondence rule as
            // Elysia's PositionSync: a changed track invalidates old UI state.
            isDraggingPosition = false
            dragPosition = 0
        }
    }

    private var transportControls: some View {
        HStack(spacing: 20) {
            Button(action: { model.playOffset(-1) }) {
                Image(systemName: "backward.fill")
            }
            .buttonStyle(.plain)
            .help("player.previous")

            Button(action: model.togglePlayPause) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .help("player.playPause")

            Button(action: { model.playOffset(1) }) {
                Image(systemName: "forward.fill")
            }
            .buttonStyle(.plain)
            .help("player.next")

            Button(action: model.cycleRepeatMode) {
                Image(systemName: model.repeatMode == .one ? "repeat.1" : "repeat")
                    .foregroundColor(model.repeatMode == .off ? .primary : .red)
            }
            .buttonStyle(.plain)
            .help("player.repeat")
        }
        .font(.title3)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(nsImage: DefaultArtwork.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .task(id: currentTrack?.coverFileName) {
                    if let track = currentTrack {
                        artwork = await library.artwork(for: track)
                    } else {
                        artwork = DefaultArtwork.image
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    Text(currentTrack?.title ?? String(localized: "player.notPlaying"))
                        .font(.system(size: 12))
                        .fontWeight(player.isPlaying ? .bold : .semibold)
                        .foregroundStyle(player.isPlaying ? Color.red : Color.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Text(currentTrack?.displayArtist ?? "—")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 6) {
                Text(formatTime(isDraggingPosition ? dragPosition : player.position))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()

                Slider(
                    value: Binding(
                        get: { isDraggingPosition ? dragPosition : player.position },
                        set: { newValue in
                            dragPosition = newValue
                            isDraggingPosition = true
                        }
                    ),
                    in: 0...max(player.duration, 1),
                    onEditingChanged: { editing in
                        if !editing {
                            player.seek(to: dragPosition)
                            isDraggingPosition = false
                        }
                    }
                )
                .controlSize(.mini)
                .tint(.red)

                Text(formatTime(player.duration))
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .animation(.easeInOut(duration: 0.15), value: player.isPlaying)
    }

    private var volumeControls: some View {
        HStack(spacing: 8) {
            Image(systemName: volumeIcon)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 18, alignment: .center)

            Slider(
                value: Binding(
                    get: { isDraggingVolume ? dragVolume : player.volume * 100 },
                    set: { newValue in
                        dragVolume = newValue
                        isDraggingVolume = true
                    }
                ),
                in: 0...100,
                onEditingChanged: { editing in
                    if editing {
                        isDraggingVolume = true
                    } else {
                        player.setVolume(dragVolume / 100)
                        isDraggingVolume = false
                    }
                }
            )
            .onChange(of: dragVolume) { _, newValue in
                if isDraggingVolume {
                    player.setVolume(newValue / 100)
                }
            }
            .controlSize(.mini)
            .tint(.red)
            .frame(width: 80, height: 12)
        }
    }

    private var volumeIcon: String {
        let value = isDraggingVolume ? dragVolume : player.volume * 100
        if value <= 0 { return "speaker.slash.fill" }
        if value < 33 { return "speaker.fill" }
        if value < 66 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
