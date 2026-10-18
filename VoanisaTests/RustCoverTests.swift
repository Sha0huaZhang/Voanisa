import CoreGraphics
import ImageIO
import XCTest
@testable import Voanisa

/// Cover art is cropped and encoded by the Rust core now, with ImageIO kept only
/// for formats `image` cannot decode such as HEIC.
final class RustCoverTests: XCTestCase {
    private var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    private func artworkData() throws -> Data {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-art-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: out) }

        XCTAssertTrue(
            RustCore.writeArtwork(url: fixtures.appendingPathComponent("tagged.m4a"), to: out)
        )
        return try Data(contentsOf: out)
    }

    func testRustRendersSquareJPEG() throws {
        let data = try artworkData()
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-src-\(UUID().uuidString).png")
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-out-\(UUID().uuidString).jpg")
        try data.write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: out)
        }

        XCTAssertTrue(RustCore.writeSquareCover(source: source, to: out, side: 512))

        let jpeg = try Data(contentsOf: out)
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]), "should be a JPEG")

        let imageSource = try XCTUnwrap(
            CGImageSourceCreateWithData(jpeg as CFData, nil)
        )
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
    }

    func testCoverRendererProducesASquare() throws {
        let jpeg = try XCTUnwrap(
            CoverRenderer.centeredSquareCoverJPEG(from: try artworkData(), side: 256)
        )
        XCTAssertEqual(jpeg.prefix(2), Data([0xFF, 0xD8]))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 256)
    }

    func testUndecodableDataFallsBackToNothing() {
        let junk = Data("definitely not an image".utf8)
        XCTAssertNil(CoverRenderer.centeredSquareCoverJPEG(from: junk))
    }
}
