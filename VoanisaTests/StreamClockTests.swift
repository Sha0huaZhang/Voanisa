import XCTest
@testable import Voanisa

/// The progress bar reads `StreamClock`; these tests pin down what it reports
/// while playing, paused and finished, which is where it used to snap to zero.
final class StreamClockTests: XCTestCase {
    func testEmptyClockStartsAtZero() {
        let clock = StreamClock()
        XCTAssertEqual(clock.seconds(rendered: nil, sampleRate: 44100), 0)
        XCTAssertEqual(clock.seconds(rendered: 0, sampleRate: 44100), 0)
    }

    func testPlayingAddsRenderedFramesToTheAnchor() {
        var clock = StreamClock()
        clock.baseFrame = 44100

        XCTAssertEqual(clock.seconds(rendered: 22050, sampleRate: 44100), 1.5)
    }

    func testPausedFrameSurvivesADryNode() {
        var clock = StreamClock()
        clock.baseFrame = 44100
        clock.pausedFrame = clock.frame(rendered: 22050)

        // A paused node reports no player time at all; the position must stay
        // exactly where the pause happened instead of falling back to 0.
        XCTAssertEqual(clock.seconds(rendered: nil, sampleRate: 44100), 1.5)
        XCTAssertEqual(clock.seconds(rendered: 999_999, sampleRate: 44100), 1.5)
    }

    func testResumeClearsTheFrozenFrame() {
        var clock = StreamClock()
        clock.pausedFrame = 88200
        clock.pausedFrame = nil
        clock.baseFrame = 88200

        XCTAssertEqual(clock.seconds(rendered: 44100, sampleRate: 44100), 3)
    }

    func testFinishedPlaybackStaysAtTheEnd() {
        var clock = StreamClock()
        clock.baseFrame = Int64((180.0 * 44100).rounded())

        XCTAssertEqual(clock.seconds(rendered: nil, sampleRate: 44100), 180, accuracy: 0.001)
    }

    func testNegativeRenderedFramesAreIgnored() {
        var clock = StreamClock()
        clock.baseFrame = 1000

        XCTAssertEqual(clock.frame(rendered: -50), 1000)
    }

    func testZeroSampleRateDoesNotDivideByZero() {
        let clock = StreamClock()
        XCTAssertEqual(clock.seconds(rendered: 0, sampleRate: 0), 0)
    }
}
