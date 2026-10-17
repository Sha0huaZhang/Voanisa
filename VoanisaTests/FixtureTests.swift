import XCTest
@testable import Voanisa

final class FixtureTests: XCTestCase {
    private var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    private var audioDirectory: URL {
        fixturesDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    private var imagesDirectory: URL {
        fixturesDirectory.appendingPathComponent("images", isDirectory: true)
    }

    func testAudioFixturesAreDetectedAsWAV() {
        for name in ["tone-a.wav", "tone-b.wav"] {
            let url = audioDirectory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
            XCTAssertEqual(AudioProbe.quickContainer(for: url), .wav, name)
        }
    }

    func testAudioFixturesProbeAsPlayableAudio() async {
        for name in ["tone-a.wav", "tone-b.wav"] {
            let url = audioDirectory.appendingPathComponent(name)
            let result = await AudioProbe.probe(url: url)

            XCTAssertTrue(result.isSupported, name)
            XCTAssertEqual(result.container, .wav, name)
            XCTAssertGreaterThan(result.duration, 0.1, name)
            XCTAssertGreaterThan(result.sampleRate, 0, name)
            XCTAssertGreaterThan(result.channelCount, 0, name)
        }
    }

    func testExpandFindsAudioFixturesInAFolder() {
        let urls = ImportService.expand(urls: [audioDirectory])

        XCTAssertEqual(
            Set(urls.map(\.lastPathComponent)),
            Set(["tone-a.wav", "tone-b.wav", "tagged.m4a"])
        )
    }

    func testExpandAcceptsADirectAudioFile() {
        let url = audioDirectory.appendingPathComponent("tone-a.wav")
        let urls = ImportService.expand(urls: [url])

        XCTAssertEqual(urls.map(\.lastPathComponent), ["tone-a.wav"])
    }

    func testPlaceholderImageFixturesLoad() {
        for name in ["cover-a.png", "cover-b.png"] {
            let url = imagesDirectory.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), name)
            XCTAssertNotNil(CoverRenderer.loadOrientedImage(url: url), name)
        }
    }

    func testMissingPlaceholderImageFallsBackToDefaultArtwork() {
        let missing = imagesDirectory.appendingPathComponent("missing-cover.png")

        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        XCTAssertNil(CoverRenderer.loadOrientedImage(url: missing))
        XCTAssertTrue(
            Artwork.image(
                for: "missing-cover.png",
                directory: imagesDirectory
            ) === DefaultArtwork.image
        )
    }
}
