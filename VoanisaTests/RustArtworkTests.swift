import XCTest
@testable import Voanisa

/// Ogg, Opus, WavPack and APE have no AVFoundation metadata, so their covers
/// can only come from the Rust core. The fixture carries a real PNG picture.
final class RustArtworkTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    func testExtractsAttachedPicture() throws {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-artwork-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }

        let wrote = RustCore.writeArtwork(
            url: fixtures.appendingPathComponent("tagged.m4a"),
            to: out
        )

        XCTAssertTrue(wrote)
        let data = try Data(contentsOf: out)
        XCTAssertGreaterThan(data.count, 100)
        XCTAssertTrue(
            data.starts(with: [0x89, 0x50, 0x4E, 0x47]),
            "tagged.m4a stores a PNG cover"
        )
    }

    func testReportsNoArtwork() {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-artwork-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertFalse(
            RustCore.writeArtwork(
                url: fixtures.appendingPathComponent("tone.ogg"),
                to: out
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.path))
    }

    func testImportFillsCoverFromRustArtwork() async {
        let candidates = await ImportService.prepare(
            urls: [fixtures.appendingPathComponent("tagged.m4a")]
        )

        XCTAssertEqual(candidates.count, 1)
        XCTAssertNotNil(candidates.first?.coverJPEG, "the sheet should show the cover")
    }
}
