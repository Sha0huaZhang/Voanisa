import AppKit
import XCTest
@testable import Voanisa

final class AudioMetadataTests: XCTestCase {
    private var audioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    private var taggedURL: URL {
        audioDirectory.appendingPathComponent("tagged.m4a")
    }

    private var untaggedURL: URL {
        audioDirectory.appendingPathComponent("tone-a.wav")
    }

    func testReadsEmbeddedTagsAndArtwork() async throws {
        let metadata = await AudioMetadataReader.read(url: taggedURL)

        XCTAssertEqual(metadata.title, "Tagged Song")
        XCTAssertEqual(metadata.artist, "Tagged Artist")
        XCTAssertEqual(metadata.album, "Tagged Album")
        XCTAssertEqual(metadata.albumArtist, "Tagged Album Artist")
        XCTAssertEqual(metadata.trackNumber, 3)
        XCTAssertEqual(metadata.discNumber, 2)

        let artwork = try XCTUnwrap(metadata.artwork)
        XCTAssertNotNil(CoverRenderer.loadOrientedImage(data: artwork))
        XCTAssertEqual(CoverRenderer.imageFileExtension(for: artwork), "png")
    }

    func testPreparePrefillsCandidateFromTagsAndCover() async throws {
        let candidates = await ImportService.prepare(urls: [taggedURL])
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.title, "Tagged Song")
        XCTAssertEqual(candidate.artist, "Tagged Artist")
        XCTAssertEqual(candidate.album, "Tagged Album")
        XCTAssertEqual(candidate.albumArtist, "Tagged Album Artist")
        XCTAssertEqual(candidate.trackNumber, 3)
        XCTAssertEqual(candidate.discNumber, 2)
        XCTAssertNil(candidate.error)

        let coverJPEG = try XCTUnwrap(candidate.coverJPEG)
        let image = try XCTUnwrap(NSImage(data: coverJPEG))
        XCTAssertEqual(image.size.width, 1024)
        XCTAssertEqual(image.size.height, 1024)
        XCTAssertNotNil(candidate.originalCoverData)
        XCTAssertEqual(candidate.originalCoverExtension, "png")
    }

    func testPrepareFallsBackToFileNameWhenTagsAreMissing() async throws {
        let candidates = await ImportService.prepare(urls: [untaggedURL])
        let candidate = try XCTUnwrap(candidates.first)

        XCTAssertEqual(candidate.title, "tone-a")
        XCTAssertEqual(candidate.artist, "")
        XCTAssertEqual(candidate.album, "")
        XCTAssertEqual(candidate.trackNumber, nil)
        XCTAssertEqual(candidate.discNumber, nil)
        XCTAssertNil(candidate.coverJPEG)
        XCTAssertNil(candidate.originalCoverData)
    }
}
