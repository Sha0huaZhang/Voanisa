import XCTest
@testable import Voanisa

/// Regression tests for the "binaries imported as MP3" bug.
///
/// The old probe accepted any file containing a single `0xFF 0xEx` pair, so XZ
/// archives, ELF binaries and other data ended up in the library with made-up
/// durations. Detection must now require a short chain of consistent frames,
/// and the import pipeline must never build a candidate for anything else.
final class ProbeHardeningTests: XCTestCase {
    private var root: URL!

    private var audioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoanisaProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// XZ magic followed by noise sprinkled with MPEG and ADTS sync words: the
    /// shape that used to be accepted as three different "audio" formats.
    private func binaryBlob() -> Data {
        var data = Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])
        data.append(Data(repeating: 0x00, count: 4096))
        data.append(contentsOf: [0xFF, 0xFB, 0x90, 0x00])
        data.append(Data(repeating: 0x5A, count: 2048))
        data.append(contentsOf: [0xFF, 0xF3, 0x48, 0x00])
        data.append(Data(repeating: 0x00, count: 512))
        data.append(contentsOf: [0xFF, 0xF1, 0x50, 0x80])
        return data
    }

    /// MPEG1 Layer III, 128 kbps, 44.1 kHz: 417-byte frames, no padding.
    private func mp3FrameChain(count: Int) -> Data {
        var data = Data()
        for _ in 0..<count {
            var frame = [UInt8](repeating: 0, count: 417)
            frame[0] = 0xFF
            frame[1] = 0xFB
            frame[2] = 0x90
            data.append(contentsOf: frame)
        }
        return data
    }

    func testBinaryIsNotRecognizedAsAudio() throws {
        let url = root.appendingPathComponent("gcry_idea.mp3")
        try binaryBlob().write(to: url)

        XCTAssertEqual(AudioProbe.quickContainer(for: url), .unknown)
    }

    func testRepeatedFrameChainIsStillRecognized() throws {
        let url = root.appendingPathComponent("tone.mp3")
        try mp3FrameChain(count: 4).write(to: url)

        XCTAssertEqual(AudioProbe.quickContainer(for: url), .mp3)
    }

    func testPrepareDropsBinariesFromFolders() async throws {
        let folder = root.appendingPathComponent("Album", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try binaryBlob().write(to: folder.appendingPathComponent("gcry_idea.mp3"))
        try FileManager.default.copyItem(
            at: audioDirectory.appendingPathComponent("tone-a.wav"),
            to: folder.appendingPathComponent("tone-a.wav")
        )

        let candidates = await ImportService.prepare(urls: [folder])

        XCTAssertEqual(candidates.map(\.sourceURL.lastPathComponent), ["tone-a.wav"])
    }

    func testPrepareDropsAnExplicitlyPickedBinary() async throws {
        let url = root.appendingPathComponent("pcidump.mp3")
        try binaryBlob().write(to: url)

        let candidates = await ImportService.prepare(urls: [url])

        XCTAssertTrue(candidates.isEmpty)
    }
}
