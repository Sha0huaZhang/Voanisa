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
    private var timer: Timer?
    private var currentTrack: Track?
    private var lastNowPlayingUpdate = Date.distantPast

    func play(track: Track) throws {
        let url = LibraryLocation.mediaURL(for: track.fileName)
        let next = try AVAudioPlayer(contentsOf: url)
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

    func togglePlayPause() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
        updateNowPlaying(force: true)
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        let value = min(max(0, seconds), max(0, player.duration))
        player.currentTime = value
        position = value
        updateNowPlaying(force: true)
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(0, value), 1)
        volume = clamped
        player?.volume = Float(clamped)
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
        currentTrack = nil
        currentTrackID = nil
        isPlaying = false
        position = 0
        duration = 0
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
        guard let player else { return }
        position = player.currentTime
        duration = player.duration
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

        if let coverName = track.coverFileName,
           let image = NSImage(contentsOf: LibraryLocation.coverURL(for: coverName)) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}
