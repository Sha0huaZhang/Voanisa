import CryptoKit
import XCTest
@testable import Voanisa

/// The Rust core owns content hashing now, so its output has to agree byte for
/// byte with the CryptoKit implementation it replaced: existing libraries were
/// deduplicated with those hashes.
final class HashParityTests: XCTestCase {
    func testRustHashMatchesCryptoKit() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-hash-\(UUID().uuidString).bin")
        // Larger than the 1 MiB read buffer, so the streaming loop is covered.
        let data = Data(repeating: 0x5A, count: (1 << 20) + 7)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let expected = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(RustCore.hashFile(url: url), expected)
    }

    func testMissingFileHasNoHash() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voanisa-missing-\(UUID().uuidString).bin")
        XCTAssertNil(RustCore.hashFile(url: url))
    }
}
