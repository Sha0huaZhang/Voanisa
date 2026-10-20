import Foundation
import MediaPlayer

enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one
}

enum PlaybackError: LocalizedError {
    case decoderUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .decoderUnavailable(let file):
            return String(format: String(localized: "error.decoder"), file)
        }
    }
}

/// Local playback for the macOS prototype.
///
/// Decoding is owned by the portable Rust core, which streams PCM into
/// AVAudioEngine for every container; the queue and repeat logic live in AppModel.
final class PlaybackEngine: ObservableObject {
    @Published private(set) var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 0.7

    var onFinished: (() -> Void)?

    /// The single decoder for every container: the Rust core supplies PCM and
    /// AVAudioEngine converts and outputs it.
    private var streamer: StreamingAudioPlayer?
    private var timer: Timer?
    private var currentTrack: Track?
    private var lastNowPlayingUpdate = Date.distantPast
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkKey: String?

    func play(track: Track) throws {
        let url = LibraryLocation.mediaURL(for: track.fileName)

        // One decoder for every format: the portable core reads the file and
        // AVAudioEngine only converts and outputs it.
        let streaming = StreamingAudioPlayer()
        guard streaming.open(url: url) else {
            Diagnostics.error("Rust 解码不可用：\(url.lastPathComponent)", context: "playback.stream")
            throw PlaybackError.decoderUnavailable(url.lastPathComponent)
        }

        streaming.setVolume(volume)
        streaming.onFinished = { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.position = self.duration
            self.updateNowPlaying(force: true)
            self.onFinished?()
        }
        streaming.play()

        streamer?.stop()
        streamer = streaming

        currentTrack = track
        currentTrackID = track.id
        isPlaying = true
        position = 0
        duration = streaming.duration
        startTimer()
        updateNowPlaying(force: true)
        Diagnostics.log(
            "播放《\(track.title)》 \(url.lastPathComponent)（Rust 解码 · \(streaming.codec)）"
        )
    }

    func togglePlayPause() {
        guard let streamer else { return }
        if streamer.isPlaying {
            streamer.pause()
            isPlaying = false
        } else if duration > 0, position >= duration - 0.25 {
            // The stream ran dry: the decoder sits at the end and would report
            // "finished" again immediately. Restart the song instead, so the
            // play button does what it says after a song has ended.
            seek(to: 0)
            streamer.play()
            isPlaying = true
        } else {
            streamer.play()
            isPlaying = true
        }
        updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        guard let streamer else { return }
        let value = min(max(0, seconds), max(0, duration))
        streamer.seek(to: value)
        position = value
        updateNowPlaying(force: true)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(0, value), 1)
        volume = clamped
        streamer?.setVolume(clamped)
    }

    /// Applies metadata edits to the currently playing song.
    func refresh(track: Track) {
        guard currentTrackID == track.id else { return }
        currentTrack = track
        updateNowPlaying(force: true)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        streamer?.stop()
        streamer = nil
        currentTrack = nil
        currentTrackID = nil
        isPlaying = false
        position = 0
        duration = 0
        nowPlayingArtwork = nil
        nowPlayingArtworkKey = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Timer

    private func startTimer() {
        timer?.invalidate()
        // 10 Hz: the progress bar moves in 100 ms steps, which reads as smooth
        // without waking the UI more often than the audio callback does.
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        guard let streamer else { return }
        position = streamer.position
        if streamer.duration > 0 {
            duration = streamer.duration
        }
        if Date().timeIntervalSince(lastNowPlayingUpdate) > 1.0 {
            updateNowPlaying(force: true)
        }
    }

    // MARK: - Now Playing

    private func updateNowPlaying(force: Bool) {
        guard force else { return }
        lastNowPlayingUpdate = Date()

        guard let track = currentTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            MPNowPlayingInfoCenter.default().playbackState = .stopped
            return
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.displayArtist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
        ]

        let artworkKey = track.coverFileName ?? "<default>"
        if artworkKey != nowPlayingArtworkKey {
            let image = Artwork.image(for: track.coverFileName)
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingArtworkKey = artworkKey
        }
        if let nowPlayingArtwork {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
