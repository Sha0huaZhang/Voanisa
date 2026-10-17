import XCTest
@testable import Voanisa

final class ImportServiceTests: XCTestCase {
    private var root: URL!

    private var audioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoanisaImport-\(UUID().uuidString)", isDirectory: true)
        try LibraryLocation.ensureDirectories(rootURL: root)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testCommitImportsAudioIntoTheLibrary() async throws {
        let candidate = try await candidate(named: "tone-a.wav")

        let outcome = try await ImportService.commit(
            candidates: [candidate],
            existing: [],
            rootURL: root
        )

        let track = try XCTUnwrap(outcome.tracks.first)
        XCTAssertTrue(outcome.failures.isEmpty)
        XCTAssertTrue(outcome.failedCandidateIDs.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Media/\(track.fileName)").path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("library.sqlite").path
            )
        )
    }

    func testDuplicateSkippingCanBeDisabled() async throws {
        let firstCandidate = try await candidate(named: "tone-a.wav")
        let first = try await ImportService.commit(
            candidates: [firstCandidate],
            existing: [],
            rootURL: root
        )

        let secondCandidate = try await candidate(named: "tone-a.wav")
        let skipped = try await ImportService.commit(
            candidates: [secondCandidate],
            existing: first.tracks,
            skipDuplicates: true,
            rootURL: root
        )
        XCTAssertEqual(skipped.skippedDuplicates, 1)
        XCTAssertTrue(skipped.tracks.isEmpty)

        let thirdCandidate = try await candidate(named: "tone-a.wav")
        let imported = try await ImportService.commit(
            candidates: [thirdCandidate],
            existing: first.tracks,
            skipDuplicates: false,
            rootURL: root
        )
        XCTAssertEqual(imported.tracks.count, 1)
    }

    func testEmptyTitleReportsFailedCandidateAndProgress() async throws {
        var candidate = try await candidate(named: "tone-a.wav")
        candidate.title = "   "
        var progress: [(Int, Int)] = []

        let outcome = try await ImportService.commit(
            candidates: [candidate],
            existing: [],
            rootURL: root
        ) { done, total in
            progress.append((done, total))
        }

        XCTAssertEqual(outcome.failures.count, 1)
        XCTAssertEqual(outcome.failedCandidateIDs, [candidate.id])
        XCTAssertTrue(outcome.tracks.isEmpty)
        XCTAssertEqual(progress.last?.0, 1)
        XCTAssertEqual(progress.last?.1, 1)
    }

    func testCancellationStopsBeforeImporting() async throws {
        let candidate = try await candidate(named: "tone-a.wav")

        let task = Task { () -> ImportOutcome in
            try? await Task.sleep(nanoseconds: 1_000_000)
            return try await ImportService.commit(
                candidates: [candidate],
                existing: [],
                rootURL: root
            )
        }
        task.cancel()

        let outcome = try await task.value

        XCTAssertTrue(outcome.cancelled)
        XCTAssertTrue(outcome.tracks.isEmpty)
    }

    private func candidate(named name: String) async throws -> ImportCandidate {
        let candidates = await ImportService.prepare(
            urls: [audioDirectory.appendingPathComponent(name)]
        )
        return try XCTUnwrap(candidates.first)
    }
}
