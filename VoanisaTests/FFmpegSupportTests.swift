import XCTest
@testable import Voanisa

final class FFmpegSupportTests: XCTestCase {
    private var root: URL!

    private var audioDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/audio", isDirectory: true)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoanisaFFmpeg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        unsetenv(FFmpegLocation.environmentKey)
    }

    // MARK: - Install commands

    func testEachInstallingToolCarriesItsOwnCommand() {
        XCTAssertEqual(FFmpegTool.homebrew.installCommand, "brew install ffmpeg")
        XCTAssertEqual(FFmpegTool.macPorts.installCommand, "sudo port install ffmpeg")
        XCTAssertEqual(FFmpegTool.fink.installCommand, "fink install ffmpeg")
        XCTAssertEqual(FFmpegTool.finx.installCommand, "finx install ffmpeg")
        XCTAssertEqual(FFmpegTool.nix.installCommand, "nix profile install nixpkgs#ffmpeg")
        XCTAssertEqual(FFmpegTool.macWave.installCommand, "wave install ffmpeg")
        XCTAssertNil(FFmpegTool.selfBuiltUSRLocal.installCommand)
        XCTAssertNil(FFmpegTool.selfBuiltLocal.installCommand)
    }

    func testInstallingToolsKeepTheWizardOrder() {
        XCTAssertEqual(
            FFmpegTool.installingTools,
            [.homebrew, .macPorts, .fink, .finx, .nix, .macWave]
        )
    }

    func testUserSuppliedPathIsTrimmedAndAcceptsTilde() throws {
        let executable = root.appendingPathComponent("bin/ffmpeg")
        try writeExecutable(to: executable)

        XCTAssertEqual(
            FFmpegLocation.resolve(path: "  \(executable.path)  ")?.standardizedFileURL,
            executable.standardizedFileURL
        )
        XCTAssertNil(FFmpegLocation.resolve(path: "   "))
        XCTAssertNil(FFmpegLocation.resolve(path: root.appendingPathComponent("missing").path))
    }

    // MARK: - Header parsing

    func testParsesWMAHeaderAndTags() {
        let output = """
        ffmpeg version 9.0.2 Copyright (c) 2000-2026 the FFmpeg developers
        [aist#0:0/wmav2 @ 0x149007b30] Guessed Channel Layout: stereo
        Input #0, asf, from 'tone.wma':
          Metadata:
            title           : Voanisa Test Tone
            artist          : Voanisa
            album           : Fixtures
            track           : 3/12
            creation_time   : 1970-01-01T00:00:00.000000Z
          Duration: 00:00:00.32, start: 0.000000, bitrate: 92 kb/s
          Stream #0:0: Audio: wmav2 (a[1][0][0] / 0x0161), 22050 Hz, stereo, fltp, 64 kb/s
        At least one output file must be specified
        """

        let info = FFmpeg.parse(output)

        XCTAssertEqual(info.codec, "wmav2")
        XCTAssertEqual(info.sampleRate, 22050)
        XCTAssertEqual(info.channelCount, 2)
        XCTAssertEqual(info.duration, 0.32, accuracy: 0.001)
        XCTAssertEqual(info.tags["title"], "Voanisa Test Tone")
        XCTAssertEqual(info.tags["track"], "3/12")
        XCTAssertNil(info.tags["creation_time"])
    }

    func testParsesMonoAndPlainChannelCounts() {
        let mono = """
        Input #0, asf, from 'x.wma':
          Duration: 00:01:02.50, start: 0.000000, bitrate: 96 kb/s
          Stream #0:0: Audio: wmapro, 44100 Hz, mono, fltp, 96 kb/s
        """
        let five = """
        Input #0, asf, from 'y.wma':
          Duration: N/A, start: 0.000000, bitrate: 320 kb/s
          Stream #0:0: Audio: wmav2, 48000 Hz, 5 channels, fltp, 320 kb/s
        """

        XCTAssertEqual(FFmpeg.parse(mono).channelCount, 1)
        XCTAssertEqual(FFmpeg.parse(mono).duration, 62.5, accuracy: 0.001)
        XCTAssertEqual(FFmpeg.parse(five).channelCount, 5)
        XCTAssertEqual(FFmpeg.parse(five).duration, 0)
    }

    func testIgnoresOutputThatIsNotAHeader() {
        XCTAssertEqual(FFmpeg.parse("ffmpeg: command not found"), FFmpegMediaInfo())
    }

    func testRunsDetectsABinaryThatStarts() throws {
        let script = root.appendingPathComponent("ffmpeg")
        try writeExecutable(to: script, contents: "#!/bin/sh\nexit 0\n")

        XCTAssertTrue(FFmpeg.runs(script))
        XCTAssertFalse(FFmpeg.runs(root.appendingPathComponent("missing")))
    }

    // MARK: - MacWave

    func testMacWaveConfigPrefersTheSystemInstall() throws {
        let systemBase = root.appendingPathComponent("system-base", isDirectory: true)
        let userBase = root.appendingPathComponent("user-base", isDirectory: true)
        let systemConfig = root.appendingPathComponent("opt/macwave_config/config.json")
        let userConfig = root.appendingPathComponent("home/.config/macwave_config/config.json")

        try write(#"{"base_dir": "\#(systemBase.path)"}"#, to: systemConfig)
        try write(#"{"base_dir": "\#(userBase.path)"}"#, to: userConfig)

        let userInstall = root.appendingPathComponent(".local/macwave", isDirectory: true)
        let resolved = MacWaveConfiguration.baseDirectories(
            systemConfig: systemConfig,
            userConfig: userConfig,
            userInstall: userInstall
        )
        XCTAssertEqual(resolved.first?.standardizedFileURL, systemBase.standardizedFileURL)
        XCTAssertEqual(resolved[1].standardizedFileURL, userBase.standardizedFileURL)

        try FileManager.default.removeItem(at: systemConfig)
        let fallback = MacWaveConfiguration.baseDirectories(
            systemConfig: systemConfig,
            userConfig: userConfig,
            userInstall: userInstall
        )
        XCTAssertEqual(fallback.first?.standardizedFileURL, userBase.standardizedFileURL)
    }

    func testMacWaveConfigRejectsBrokenOrMissingFiles() throws {
        let config = root.appendingPathComponent("broken/config.json")
        try write("not json", to: config)

        let userInstall = root.appendingPathComponent(".local/macwave", isDirectory: true)
        XCTAssertEqual(
            MacWaveConfiguration.baseDirectories(
                systemConfig: config,
                userConfig: root.appendingPathComponent("absent.json"),
                userInstall: userInstall
            ).map(\.standardizedFileURL),
            [userInstall.standardizedFileURL]
        )
        XCTAssertNil(MacWaveConfiguration.installedBaseDirectory(
            systemConfig: config,
            userConfig: root.appendingPathComponent("absent.json"),
            userInstall: userInstall
        ))
    }

    func testMacWaveFindsTheNewestVersionedBinary() throws {
        let base = root.appendingPathComponent("macwave", isDirectory: true)
        try writeExecutable(to: base.appendingPathComponent("bin/ffmpeg@1.0.0/ffmpeg"))
        try writeExecutable(to: base.appendingPathComponent("bin/ffmpeg@1.9.0/ffmpeg"))
        try writeExecutable(to: base.appendingPathComponent("bin/ffmpeg@1.10.0/ffmpeg"))

        let binary = try XCTUnwrap(MacWaveConfiguration.binary(inBaseDirectory: base))

        XCTAssertEqual(binary.path, base.appendingPathComponent("bin/ffmpeg@1.10.0/ffmpeg").path)
    }

    func testMacWavePrefersTheLinksSymlink() throws {
        let base = root.appendingPathComponent("macwave", isDirectory: true)
        let versioned = base.appendingPathComponent("bin/ffmpeg@9.0.2/ffmpeg")
        try writeExecutable(to: versioned)

        let links = base.appendingPathComponent("links", isDirectory: true)
        try FileManager.default.createDirectory(at: links, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: links.appendingPathComponent("ffmpeg"),
            withDestinationURL: versioned
        )

        let binary = try XCTUnwrap(MacWaveConfiguration.binary(inBaseDirectory: base))
        XCTAssertEqual(binary.standardizedFileURL, versioned.standardizedFileURL)
    }

    func testMacWaveFallsBackToTheLocalInstall() throws {
        let userInstall = root.appendingPathComponent(".local/macwave", isDirectory: true)
        try writeExecutable(to: userInstall.appendingPathComponent("bin/ffmpeg@9.0.2/ffmpeg"))

        let directories = MacWaveConfiguration.baseDirectories(
            systemConfig: root.appendingPathComponent("absent-system.json"),
            userConfig: root.appendingPathComponent("absent-user.json"),
            userInstall: userInstall
        )

        XCTAssertEqual(directories.last?.standardizedFileURL, userInstall.standardizedFileURL)
        XCTAssertNotNil(MacWaveConfiguration.binary(inBaseDirectory: try XCTUnwrap(directories.last)))
    }

    func testMacWaveWithoutPackagesHasNoBinary() throws {
        let base = root.appendingPathComponent("empty-macwave", isDirectory: true)
        try FileManager.default.createDirectory(
            at: base.appendingPathComponent("bin", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertNil(MacWaveConfiguration.binary(inBaseDirectory: base))
    }

    // MARK: - Copying

    func testInstallCopiesAnExecutableIntoPlace() throws {
        let source = root.appendingPathComponent("source-ffmpeg")
        try writeExecutable(to: source, contents: "#!/bin/sh\nexit 0\n")
        let destination = root.appendingPathComponent("lib/ffmpeg")

        try FFmpegLocation.install(from: source, to: destination)

        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: destination.path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "#!/bin/sh\nexit 0\n")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("lib/ffmpeg.copying").path
            )
        )
    }

    func testInstallReplacesAnExistingCopy() throws {
        let destination = root.appendingPathComponent("lib/ffmpeg")
        let first = root.appendingPathComponent("ffmpeg-v1")
        let second = root.appendingPathComponent("ffmpeg-v2")
        try writeExecutable(to: first, contents: "#!/bin/sh\necho v1\n")
        try writeExecutable(to: second, contents: "#!/bin/sh\necho v2\n")

        try FFmpegLocation.install(from: first, to: destination)
        try FFmpegLocation.install(from: second, to: destination)

        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "#!/bin/sh\necho v2\n")
    }

    func testInstallRejectsANonExecutable() throws {
        let source = root.appendingPathComponent("notes.txt")
        try write("just text", to: source)

        XCTAssertThrowsError(
            try FFmpegLocation.install(from: source, to: root.appendingPathComponent("lib/ffmpeg"))
        ) { error in
            XCTAssertEqual(error as? FFmpegSetupError, .notExecutable)
        }
    }

    func testInstallRejectsCopyingTheCopyOntoItself() throws {
        let destination = root.appendingPathComponent("lib/ffmpeg")
        try writeExecutable(to: destination)

        XCTAssertThrowsError(try FFmpegLocation.install(from: destination, to: destination)) { error in
            XCTAssertEqual(error as? FFmpegSetupError, .alreadyInPlace)
        }
    }

    func testBinaryFollowsTheEnvironmentOverride() throws {
        let source = root.appendingPathComponent("ffmpeg")
        try writeExecutable(to: source)

        setenv(FFmpegLocation.environmentKey, source.path, 1)
        XCTAssertEqual(FFmpegLocation.binary?.standardizedFileURL, source.standardizedFileURL)

        setenv(FFmpegLocation.environmentKey, root.appendingPathComponent("missing").path, 1)
        XCTAssertNil(FFmpegLocation.binary)
    }

    // MARK: - WMA end to end

    func testWMAIsProbedAndConvertedToFLAC() async throws {
        guard let ffmpeg = availableFFmpeg() else {
            throw XCTSkip("No ffmpeg on this Mac")
        }
        setenv(FFmpegLocation.environmentKey, ffmpeg.path, 1)

        let fixture = audioDirectory.appendingPathComponent("tone.wma")
        let probe = await AudioProbe.probe(url: fixture)

        XCTAssertEqual(probe.container, .wma)
        XCTAssertTrue(probe.isSupported)
        XCTAssertTrue(probe.requiresTranscode)
        XCTAssertEqual(probe.codec, "wmav2")
        XCTAssertGreaterThan(probe.duration, 0.2)

        let candidates = await ImportService.prepare(urls: [fixture])
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertNil(candidate.error)

        let library = root.appendingPathComponent("Library", isDirectory: true)
        try LibraryLocation.ensureDirectories(rootURL: library)
        let outcome = try await ImportService.commit(
            candidates: [candidate],
            existing: [],
            rootURL: library
        )

        let track = try XCTUnwrap(outcome.tracks.first)
        XCTAssertTrue(outcome.failures.isEmpty, "\(outcome.failures)")
        XCTAssertTrue(track.fileName.hasSuffix(".flac"))
        XCTAssertEqual(track.format, String(localized: "format.wmaTranscoded"))

        let stored = library.appendingPathComponent("Media/\(track.fileName)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        // The whole point of converting: the portable core can open the copy.
        XCTAssertNotNil(RustCore.decoderInfo(url: stored))
    }

    // MARK: - Helpers

    /// Any ffmpeg on this Mac, so the end-to-end test runs where one exists and
    /// is skipped where it does not.
    private func availableFFmpeg() -> URL? {
        for tool in FFmpegTool.allCases where tool != .macWave {
            if let url = FFmpegLocation.resolve(tool) { return url }
        }
        if let base = MacWaveConfiguration.installedBaseDirectory(),
           let binary = MacWaveConfiguration.binary(inBaseDirectory: base) {
            return binary
        }
        return FFmpegLocation.scanPath()
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeExecutable(
        to url: URL,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws {
        try write(contents, to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }
}
