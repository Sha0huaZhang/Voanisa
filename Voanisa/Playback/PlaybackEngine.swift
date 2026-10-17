import AppKit
import AVFoundation
import Foundation
import MediaPlayer

enum RepeatMode: String, CaseIterable, Sendable {
    case off
    case all
    case one
}

/// Local playback for the macOS prototype.
///
/// This is the platform layer: AVFoundation owns decoding and output, while the
/// queue and repeat logic live in AppModel. The portable Rust core can later
/// feed PCM into the same AVAudioEngine without changing the UI.
final class PlaybackEngine: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var currentTrackID: UUID?
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var volume: Double = 0.7

    var onFinished: (() -> Void)?

    private var player: AVAudioPlayer?
    /// Used for containers AVFoundation cannot decode; the Rust core supplies
    /// the PCM. Only one of `player` and `streamer` is alive at a time.
    private var streamer: StreamingAudioPlayer?
    private var timer: Timer?
    private var currentTrack: Track?
    private var lastNowPlayingUpdate = Date.distantPast
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var nowPlayingArtworkKey: String?

    func play(track: Track) throws {
        let url = LibraryLocation.mediaURL(for: track.fileName)

        let next: AVAudioPlayer
        do {
            next = try AVAudioPlayer(contentsOf: url)
        } catch {
            guard startStreaming(track: track, url: url) else { throw error }
            return
        }

        streamer?.stop()
        streamer = nil
        next.delegate = self
        next.volume = Float(volume)
        next.prepareToPlay()
        next.play()

        player?.stop()
        player = next
        currentTrack = track
        currentTrackID = track.id
        isPlaying = true
        position = 0
        duration = next.duration
        startTimer()
        updateNowPlaying(force: true)
        Diagnostics.log("播放《\(track.title)》 \(url.lastPathComponent)")
    }

    /// Fallback for Ogg, Opus and other containers AVFoundation rejects.
    private func startStreaming(track: Track, url: URL) -> Bool {
        let streaming = StreamingAudioPlayer()
        guard streaming.open(url: url) else {
            Diagnostics.error("Rust 解码不可用", context: "playback.stream")
            return false
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

        player?.stop()
        player = nil
        streamer?.stop()
        streamer = streaming

        currentTrack = track
        currentTrackID = track.id
        isPlaying = true
        position = 0
        duration = streaming.duration
        startTimer()
        updateNowPlaying(force: true)
        Diagnostics.log("播放《\(track.title)》 \(url.lastPathComponent)（Rust 解码）")
        return true
    }

    func togglePlayPause() {
        if let player {
            if player.isPlaying {
                player.pause()
                isPlaying = false
            } else {
                player.play()
                isPlaying = true
            }
        } else if let streamer {
            if streamer.isPlaying {
                streamer.pause()
                isPlaying = false
            } else {
                streamer.play()
                isPlaying = true
            }
        }
        updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        if let player {
            let value = min(max(0, seconds), max(0, player.duration))
            player.currentTime = value
            position = value
        } else if let streamer {
            let value = min(max(0, seconds), max(0, duration))
            streamer.seek(to: value)
            position = value
        }
        updateNowPlaying(force: true)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(0, value), 1)
        volume = clamped
        player?.volume = Float(clamped)
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
        player?.stop()
        player = nil
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
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        if let player {
            position = player.currentTime
            duration = player.duration
        } else if let streamer {
            position = streamer.position
            if streamer.duration > 0 {
                duration = streamer.duration
            }
        } else {
            return
        }
        if Date().timeIntervalSince(lastNowPlayingUpdate) > 1.0 {
            updateNowPlaying(force: true)
        }
    }

    // MARK: - AVAudioPlayerDelegate

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isPlaying = false
            self.position = self.duration
            self.updateNowPlaying(force: true)
            self.onFinished?()
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
