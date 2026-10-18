import XCTest
@testable import Voanisa

/// Playback now prefers the Rust decoder for every container, with AVFoundation
/// only as a fallback, so the core has to handle the native formats too.
final class NativeDecodeTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    func testCoreDecodesEveryNativeFixture() throws {
        for name in ["tone-a.wav", "tagged.m4a"] {
            let decoder = try XCTUnwrap(
                RustAudioDecoder(url: fixtures.appendingPathComponent(name)),
                name
            )
            XCTAssertGreaterThan(decoder.info.durationSeconds, 0, name)
            XCTAssertGreaterThan(decoder.info.channels, 0, name)

            let samples = try XCTUnwrap(decoder.read(frames: 2048), name)
            XCTAssertFalse(samples.isEmpty, name)
            XCTAssertTrue(
                samples.contains { abs($0) > 0.001 },
                "\(name) should not decode to silence"
            )
            decoder.close()
        }
    }

    func testCoreSeeksInsideAnM4A() throws {
        let decoder = try XCTUnwrap(
            RustAudioDecoder(url: fixtures.appendingPathComponent("tagged.m4a"))
        )
        defer { decoder.close() }

        XCTAssertTrue(decoder.seek(to: 0.1))
        XCTAssertEqual(decoder.position, 0.1, accuracy: 0.15)
        XCTAssertNotNil(decoder.read(frames: 512))
    }

    func testMissingFileDoesNotOpen() {
        XCTAssertNil(
            RustAudioDecoder(
                url: FileManager.default.temporaryDirectory
                    .appendingPathComponent("voanisa-none-\(UUID().uuidString).mp3")
            )
        )
    }
}
