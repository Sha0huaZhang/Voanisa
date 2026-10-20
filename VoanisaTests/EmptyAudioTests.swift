import XCTest
@testable import Voanisa

/// Guards the guard: a file with no decodable frames must never reach the audio
/// graph. Otherwise the stream reports "finished" on its first pump, and in
/// repeat-one mode that turns into an endless seek/play/finish loop.
final class EmptyAudioTests: XCTestCase {
    func testRejectsAFileWithNoDecodableFrames() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).wav")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(StreamingAudioPlayer().open(url: url))
    }

    func testRejectsAMissingFile() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).flac")

        XCTAssertFalse(StreamingAudioPlayer().open(url: url))
    }
}
