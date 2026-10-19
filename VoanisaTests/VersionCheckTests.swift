import XCTest
@testable import Voanisa

final class VersionCheckTests: XCTestCase {
    func testParsesTagsWithPrefixAndSuffix() {
        XCTAssertEqual(VersionCheck.components("v1.2.3"), [1, 2, 3])
        XCTAssertEqual(VersionCheck.components("1.2.3-beta.1"), [1, 2, 3])
        XCTAssertEqual(VersionCheck.components("  2.0 "), [2, 0])
        XCTAssertEqual(VersionCheck.components(""), [])
    }

    func testComparesSegmentBySegment() {
        XCTAssertTrue(VersionCheck.isNewer("0.2.0", than: "0.1.9"))
        XCTAssertFalse(VersionCheck.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertTrue(VersionCheck.isNewer("1.0", than: "0.9.9"))
        XCTAssertFalse(VersionCheck.isNewer("1.0.0", than: "1.0"))
    }

    func testOutcomeNeedsAUsableTag() {
        XCTAssertEqual(VersionCheck.outcome(current: "0.1.0", latestTag: nil), .failed)
        XCTAssertEqual(VersionCheck.outcome(current: "0.1.0", latestTag: "v"), .failed)
        XCTAssertEqual(VersionCheck.outcome(current: "0.1.0", latestTag: "v0.1.0"), .upToDate)
        XCTAssertEqual(
            VersionCheck.outcome(current: "0.1.0", latestTag: "v0.2.0"),
            .updateAvailable(latest: "0.2.0")
        )
    }

    func testDisplayDropsThePrefix() {
        XCTAssertEqual(VersionCheck.display("v1.4.0"), "1.4.0")
        XCTAssertEqual(VersionCheck.display(" V2.0 "), "2.0")
    }
}
