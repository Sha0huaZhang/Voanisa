import AppKit
import XCTest
@testable import Voanisa

final class ArtworkTests: XCTestCase {
    private var imagesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/images", isDirectory: true)
    }

    func testMissingCoverUsesDefaultArtwork() {
        XCTAssertTrue(
            Artwork.image(for: nil, directory: imagesDirectory) === DefaultArtwork.image
        )
        XCTAssertTrue(
            Artwork.image(
                for: "missing-cover.png",
                directory: imagesDirectory
            ) === DefaultArtwork.image
        )
    }

    func testExistingCoverIsLoaded() {
        let image = Artwork.image(for: "cover-a.png", directory: imagesDirectory)

        XCTAssertFalse(image === DefaultArtwork.image)
        XCTAssertGreaterThan(image.size.width, 0)
    }

    func testDefaultArtworkIsGrayscaleWithADarkNote() throws {
        let cgImage = try XCTUnwrap(
            DefaultArtwork.image.cgImage(
                forProposedRect: nil,
                context: nil,
                hints: nil
            )
        )

        let side = 128
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            context?.draw(
                cgImage,
                in: CGRect(x: 0, y: 0, width: side, height: side)
            )
        }

        var minLuma = 1.0
        var maxLuma = 0.0
        var nonGrayPixels = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255

            if abs(red - green) > 0.02 || abs(green - blue) > 0.02 {
                nonGrayPixels += 1
            }

            let luma = (red + green + blue) / 3
            minLuma = min(minLuma, luma)
            maxLuma = max(maxLuma, luma)
        }

        XCTAssertEqual(nonGrayPixels, 0, "The default artwork should be grayscale")
        XCTAssertLessThan(minLuma, 0.4, "The note should be dark gray")
        XCTAssertGreaterThan(maxLuma, 0.55, "The background should be gray")
    }
}
