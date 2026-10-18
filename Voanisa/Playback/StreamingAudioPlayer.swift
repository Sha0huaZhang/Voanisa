import AVFoundation
import Foundation

/// Plays formats AVFoundation cannot decode (Ogg Vorbis, Opus, ...) by pulling
/// PCM from the Rust core and feeding it to `AVAudioEngine`.
///
/// Decoding runs on a private serial queue and stays a few buffers ahead of the
/// render thread, so file I/O never happens in the audio callback. The engine's
/// mixer converts the file's sample rate to the output device's rate.
final class StreamingAudioPlayer {
    /// Called on the main queue when the last buffered frame has played.
    var onFinished: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let queue = DispatchQueue(label: "org.macwave.Voanisa.stream", qos: .userInitiated)

    private var decoder: RustAudioDecoder?
    private var playing = false
    private var reachedEnd = false
    private var generation = 0
    private var inFlight = 0
    private var baseFrame: Int64 = 0
    private var volume: Float = 0.7

    /// 4096 frames is ~93 ms at 44.1 kHz: small enough for responsive seeking,
    /// large enough that scheduling overhead stays irrelevant.
    private let chunkFrames: AVAudioFrameCount = 4096
    private let maxInFlight = 4

    private(set) var duration: Double = 0
    private(set) var sampleRate: Double = 44100
    private(set) var channels: Int = 2
    private(set) var codec: String = ""

    var isPlaying: Bool { playing }

    var position: Double {
        guard let nodeTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: nodeTime) else {
            return Double(baseFrame) / max(sampleRate, 1)
        }
        let frames = max(0, baseFrame + playerTime.sampleTime)
        return Double(frames) / max(sampleRate, 1)
    }

    // MARK: - Transport

    /// Opens a file for streaming. Returns false when the Rust core cannot
    /// decode it or the audio graph cannot be built.
    func open(url: URL) -> Bool {
        guard let decoder = RustAudioDecoder(url: url), decoder.info.channels > 0 else {
            return false
        }
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: decoder.info.sampleRate,
            channels: AVAudioChannelCount(decoder.info.channels)
        ) else {
            decoder.close()
            return false
        }

        self.decoder = decoder
        duration = decoder.info.durationSeconds
        sampleRate = decoder.info.sampleRate
        channels = decoder.info.channels
        codec = decoder.info.codec
        baseFrame = 0
        reachedEnd = false
        inFlight = 0
        playing = false

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.volume = volume

        do {
            try engine.start()
        } catch {
            Diagnostics.error(error.localizedDescription, context: "stream.engine")
            decoder.close()
            self.decoder = nil
            return false
        }
        return true
    }

    func play() {
        queue.async { [weak self] in
            guard let self, self.decoder != nil else { return }
            if !self.engine.isRunning {
                try? self.engine.start()
            }
            self.playing = true
            self.node.play()
            self.pump()
        }
    }

    func pause() {
        queue.async { [weak self] in
            guard let self else { return }
            self.playing = false
            self.node.pause()
        }
    }

    func seek(to seconds: Double) {
        queue.async { [weak self] in
            guard let self, let decoder = self.decoder else { return }

            self.generation += 1
            self.node.stop()
            self.inFlight = 0
            self.reachedEnd = false

            _ = decoder.seek(to: seconds)
            self.baseFrame = Int64((seconds * decoder.info.sampleRate).rounded())

            if self.playing {
                self.node.play()
                self.pump()
            }
        }
    }

    func setVolume(_ value: Double) {
        volume = Float(min(max(0, value), 1))
        node.volume = volume
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.generation += 1
            self.playing = false
            self.reachedEnd = true
            self.inFlight = 0
            self.node.stop()
            self.engine.stop()
            self.decoder?.close()
            self.decoder = nil
        }
    }

    // MARK: - Buffering

    /// Keeps up to `maxInFlight` buffers queued on the player node.
    /// Must run on `queue`.
    private func pump() {
        guard playing, let decoder else { return }

        while inFlight < maxInFlight, !reachedEnd {
            guard let buffer = makeBuffer(decoder: decoder) else {
                reachedEnd = true
                break
            }

            let isLast = reachedEnd
            let generation = generation
            inFlight += 1

            node.scheduleBuffer(buffer) { [weak self] in
                guard let self else { return }
                self.queue.async {
                    guard generation == self.generation else { return }
                    self.inFlight = max(0, self.inFlight - 1)
                    if isLast {
                        self.finish()
                    } else {
                        self.pump()
                    }
                }
            }
        }

        // An empty first chunk means there was nothing to play at all.
        if inFlight == 0, reachedEnd {
            finish()
        }
    }

    /// Decodes one chunk into an engine buffer. Sets `reachedEnd` when the file
    /// is exhausted. Must run on `queue`.
    private func makeBuffer(decoder: RustAudioDecoder) -> AVAudioPCMBuffer? {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: decoder.info.sampleRate,
            channels: AVAudioChannelCount(decoder.info.channels)
        ), let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            return nil
        }

        guard let samples = decoder.read(frames: Int(chunkFrames)) else {
            return nil
        }

        let channelCount = decoder.info.channels
        let frames = samples.count / channelCount
        guard frames > 0, let channels = buffer.floatChannelData else {
            return nil
        }

        for channel in 0..<channelCount {
            for frame in 0..<frames {
                channels[channel][frame] = samples[frame * channelCount + channel]
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        if frames < Int(chunkFrames) {
            reachedEnd = true
        }
        return buffer
    }

    private func finish() {
        playing = false
        DispatchQueue.main.async { [weak self] in
            self?.onFinished?()
        }
    }
}
