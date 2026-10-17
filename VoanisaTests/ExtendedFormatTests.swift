import XCTest
@testable import Voanisa

/// Covers the Rust-backed path added for containers AVFoundation cannot open.
final class ExtendedFormatTests: XCTestCase {
    private var audioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    private func fixture(_ name: String) -> URL {
        audioDirectory.appendingPathComponent(name)
    }

    func testOGGAndOpusProbeAsPlayable() async {
        for name in ["tone.ogg", "tone.opus"] {
            let result = await AudioProbe.probe(url: fixture(name))

            XCTAssertTrue(result.isSupported, name)
            XCTAssertGreaterThan(result.duration, 0.2, name)
            XCTAssertEqual(result.channelCount, 2, name)
            XCTAssertGreaterThan(result.sampleRate, 0, name)
        }
    }

    func testAPEAndWavPackProbeAsPlayable() async {
        let ape = await AudioProbe.probe(url: fixture("tone.ape"))
        XCTAssertTrue(ape.isSupported)
        XCTAssertEqual(ape.container, .ape)
        XCTAssertEqual(ape.sampleRate, 44_100, accuracy: 1)
        XCTAssertEqual(ape.duration, 1.0, accuracy: 0.02)

        let wavPack = await AudioProbe.probe(url: fixture("tone.wv"))
        XCTAssertTrue(wavPack.isSupported)
        XCTAssertEqual(wavPack.container, .wavpack)
        XCTAssertEqual(wavPack.sampleRate, 22_050, accuracy: 1)
        XCTAssertEqual(wavPack.duration, 0.3, accuracy: 0.02)
    }

    func testAPEAndWavPackExposeStreamInfo() throws {
        let ape = try XCTUnwrap(RustCore.decoderInfo(url: fixture("tone.ape")))
        XCTAssertEqual(ape.container, "ape")
        XCTAssertEqual(ape.channels, 2)
        XCTAssertEqual(ape.durationSeconds, 1.0, accuracy: 0.02)

        let wavPack = try XCTUnwrap(RustCore.decoderInfo(url: fixture("tone.wv")))
        XCTAssertEqual(wavPack.container, "wavpack")
        XCTAssertEqual(wavPack.channels, 2)
        XCTAssertEqual(wavPack.durationSeconds, 0.3, accuracy: 0.02)
    }

    func testDecoderStreamsAPE() throws {
        let decoder = try XCTUnwrap(RustAudioDecoder(url: fixture("tone.ape")))
        XCTAssertEqual(decoder.info.sampleRate, 44_100, accuracy: 1)

        let head = try XCTUnwrap(decoder.read(frames: 1024))
        XCTAssertEqual(head.count, 1024 * decoder.info.channels)
        // Reference decoder sample 1 is 1002 / 32768.
        XCTAssertEqual(Double(head[2]), 1002.0 / 32768.0, accuracy: 1e-6)

        XCTAssertTrue(decoder.seek(to: 0.5))
        let tail = try XCTUnwrap(decoder.read(frames: 44_100))
        XCTAssertFalse(tail.isEmpty)
    }

    func testOGGAndOpusExposeStreamInfo() throws {
        let ogg = try XCTUnwrap(RustCore.decoderInfo(url: fixture("tone.ogg")))
        XCTAssertEqual(ogg.container, "ogg")
        XCTAssertEqual(ogg.channels, 2)
        XCTAssertEqual(ogg.sampleRate, 22050, accuracy: 1)
        XCTAssertEqual(ogg.durationSeconds, 0.3, accuracy: 0.05)

        let opus = try XCTUnwrap(RustCore.decoderInfo(url: fixture("tone.opus")))
        XCTAssertEqual(opus.container, "opus")
        XCTAssertEqual(opus.sampleRate, 48000, accuracy: 1)
        XCTAssertEqual(opus.durationSeconds, 0.3, accuracy: 0.05)
    }

    func testDecoderStreamsPCMAndSeeks() throws {
        let decoder = try XCTUnwrap(RustAudioDecoder(url: fixture("tone.opus")))

        let first = try XCTUnwrap(decoder.read(frames: 2048))
        XCTAssertEqual(first.count, 2048 * decoder.info.channels)
        XCTAssertGreaterThan(decoder.position, 0)

        XCTAssertTrue(decoder.seek(to: 0.2))
        let tail = try XCTUnwrap(decoder.read(frames: 4800))
        XCTAssertFalse(tail.isEmpty)
        XCTAssertGreaterThan(decoder.position, 0.25)
    }

    func testRustTagsAreReadFromOggOpusAPEAndWavPack() throws {
        for name in ["tagged.ogg", "tagged.opus", "tagged.ape", "tagged.wv"] {
            let tags = try XCTUnwrap(RustCore.tags(url: fixture(name)), name)
            XCTAssertEqual(tags.title, "Voanisa Test Tone", name)
            XCTAssertEqual(tags.artist, "Voanisa", name)
            XCTAssertEqual(tags.album, "Fixtures", name)
            XCTAssertEqual(tags.trackNumber, 1, name)
            XCTAssertGreaterThan(tags.durationSeconds, 0.2, name)
        }
    }

    func testUnsupportedContainerStaysUnplayable() async {
        // WMA is recognised by its signature but has no pure-Rust decoder.
        let result = await AudioProbe.probe(url: fixture("tone.wma"))

        XCTAssertEqual(result.container, .wma)
        XCTAssertFalse(result.isSupported)
        XCTAssertNil(RustCore.decoderInfo(url: fixture("tone.wma")))
    }

    func testImportPrefillsTagsFromOgg() async {
        let candidates = await ImportService.prepare(urls: [fixture("tagged.ogg")])

        XCTAssertEqual(candidates.count, 1)
        let candidate = try? XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate?.title, "Voanisa Test Tone")
        XCTAssertEqual(candidate?.artist, "Voanisa")
        XCTAssertEqual(candidate?.album, "Fixtures")
        XCTAssertEqual(candidate?.trackNumber, 1)
        XCTAssertTrue(candidate?.probe.isSupported == true)
    }

    func testImportPrefillsTagsFromAPE() async {
        let candidates = await ImportService.prepare(urls: [fixture("tagged.ape")])

        XCTAssertEqual(candidates.count, 1)
        let candidate = try? XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate?.title, "Voanisa Test Tone")
        XCTAssertEqual(candidate?.album, "Fixtures")
        XCTAssertTrue(candidate?.probe.isSupported == true)
    }

    /// End-to-end check that the engine really consumes the Rust PCM stream.
    func testStreamingPlayerReachesTheEndOfTheFile() throws {
        let player = StreamingAudioPlayer()
        guard player.open(url: fixture("tone.opus")) else {
            throw XCTSkip("no audio output device available")
        }

        let finished = expectation(description: "playback finished")
        player.onFinished = { finished.fulfill() }
        player.play()
        wait(for: [finished], timeout: 5)
        player.stop()
    }
}
