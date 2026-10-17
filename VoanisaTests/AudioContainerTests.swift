import XCTest
@testable import Voanisa

final class AudioContainerTests: XCTestCase {
    func testNativeContainers() {
        let native: [AudioContainer] = [.mp3, .aac, .m4a, .mp4, .mov, .flac, .wav, .aiff, .caf]
        for container in native {
            XCTAssertTrue(container.isNative, "\(container.rawValue) should be native")
        }
    }

    func testExtendedContainersAreNotNative() {
        let extended: [AudioContainer] = [.ogg, .opus, .mkv, .webm, .wma, .ape, .wavpack, .dsf, .dff]
        for container in extended {
            XCTAssertFalse(container.isNative, "\(container.rawValue) should need an extension decoder")
        }
    }

    func testRawValueRoundTrip() {
        for container in AudioContainer.allTestCases {
            XCTAssertEqual(AudioContainer(rawValue: container.rawValue), container)
            XCTAssertFalse(container.displayName.isEmpty)
        }
    }
}

private extension AudioContainer {
    static let allTestCases: [AudioContainer] = [
        .mp3, .aac, .m4a, .mp4, .mov, .flac, .wav, .aiff, .caf,
        .ogg, .opus, .mkv, .webm, .wma, .ape, .wavpack, .dsf, .dff, .unknown
    ]
}
