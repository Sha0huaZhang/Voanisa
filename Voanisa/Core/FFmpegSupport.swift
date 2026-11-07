import Foundation

/// An ffmpeg the user already has on this Mac, and the command that installs one.
///
/// Voanisa never ships and never downloads ffmpeg: the setup wizard only copies
/// a binary that is already on this Mac into Voanisa's own folder. Every byte
/// stays on the machine, so no GPL copy is ever conveyed to a third party.
enum FFmpegTool: String, CaseIterable, Identifiable {
    case homebrew
    case macPorts
    case fink
    case finx
    case nix
    case macWave
    case selfBuiltUSRLocal
    case selfBuiltLocal

    var id: String { rawValue }

    var title: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .macPorts: return "MacPorts"
        case .fink: return "Fink"
        case .finx: return "Finx"
        case .nix: return "Nix"
        case .macWave: return "MacWave"
        case .selfBuiltUSRLocal: return String(localized: "wma.tool.selfBuiltUSRLocal")
        case .selfBuiltLocal: return String(localized: "wma.tool.selfBuiltLocal")
        }
    }

    /// The command that installs ffmpeg with this tool. `nil` means there is
    /// nothing to install: the user built it themselves.
    var installCommand: String? {
        switch self {
        case .homebrew: return "brew install ffmpeg"
        case .macPorts: return "sudo port install ffmpeg"
        case .fink: return "fink install ffmpeg"
        case .finx: return "finx install ffmpeg"
        case .nix: return "nix profile install nixpkgs#ffmpeg"
        case .macWave: return "wave install ffmpeg"
        case .selfBuiltUSRLocal, .selfBuiltLocal: return nil
        }
    }

    /// The tools that can install ffmpeg, in the order the wizard lists them.
    static var installingTools: [FFmpegTool] {
        allCases.filter { $0.installCommand != nil }
    }

    /// Where this tool puts ffmpeg, most likely first.
    var searchPaths: [URL] {
        switch self {
        case .homebrew:
            return Self.urls(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])
        case .macPorts:
            return Self.urls(["/opt/local/bin/ffmpeg"])
        case .fink:
            return Self.urls(["/sw/bin/ffmpeg"])
        case .finx:
            return Self.urls([
                "/opt/finx/bin/ffmpeg", "~/.finx/bin/ffmpeg", "~/.local/finx/bin/ffmpeg"
            ])
        case .nix:
            return Self.urls([
                "/nix/var/nix/profiles/default/bin/ffmpeg", "~/.nix-profile/bin/ffmpeg"
            ])
        case .macWave:
            // MacWave keeps everything under a configurable base directory, so
            // its ffmpeg is found through its config rather than a fixed path.
            return []
        case .selfBuiltUSRLocal:
            return Self.urls(["/usr/local/bin/ffmpeg", "/usr/local/ffmpeg/bin/ffmpeg"])
        case .selfBuiltLocal:
            return Self.urls(["~/.local/bin/ffmpeg", "~/.local/ffmpeg/bin/ffmpeg"])
        }
    }

    private static func urls(_ paths: [String]) -> [URL] {
        paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    }
}

/// MacWave's own config decides where its packages live.
///
/// The system install wins over the user install, exactly as MacWave resolves
/// it: `/opt/macwave_config/config.json` first, then
/// `~/.config/macwave_config/config.json`. Both hold `{"base_dir": "…"}`. A
/// user-level install that keeps its packages directly under `~/.local/macwave`
/// is the last candidate.
enum MacWaveConfiguration {
    static let systemConfigFile = URL(fileURLWithPath: "/opt/macwave_config/config.json")

    static var userConfigFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("macwave_config", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    static var userInstallDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("macwave", isDirectory: true)
    }

    /// Every place a MacWave install could be, system first.
    ///
    /// Config files that do not exist are skipped, and the plain user install is
    /// always last, so a missing config still finds an existing `~/.local/macwave`.
    static func baseDirectories(
        systemConfig: URL = systemConfigFile,
        userConfig: URL = userConfigFile,
        userInstall: URL = userInstallDirectory
    ) -> [URL] {
        var directories: [URL] = []
        for file in [systemConfig, userConfig] {
            if let directory = baseDirectory(inConfig: file) { directories.append(directory) }
        }
        directories.append(userInstall)
        return directories
    }

    /// The base directory of an installed MacWave, or `nil` when none of the
    /// candidates actually holds an ffmpeg.
    static func installedBaseDirectory(
        systemConfig: URL = systemConfigFile,
        userConfig: URL = userConfigFile,
        userInstall: URL = userInstallDirectory
    ) -> URL? {
        baseDirectories(
            systemConfig: systemConfig,
            userConfig: userConfig,
            userInstall: userInstall
        )
        .first { binary(inBaseDirectory: $0) != nil }
    }

    private static func baseDirectory(inConfig file: URL) -> URL? {
        guard let data = try? Data(contentsOf: file),
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let raw = object["base_dir"] as? String,
              !raw.isEmpty else {
            return nil
        }
        return URL(
            fileURLWithPath: (raw as NSString).expandingTildeInPath,
            isDirectory: true
        )
    }

    /// MacWave installs each package as `bin/<name>@<version>/<binary>` and adds
    /// a plain `links/<name>` symlink to the newest one.
    static func binary(inBaseDirectory base: URL) -> URL? {
        let link = base.appendingPathComponent("links", isDirectory: true)
            .appendingPathComponent("ffmpeg")
        if isExecutable(link) { return link.resolvingSymlinksInPath() }

        let bin = base.appendingPathComponent("bin", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: bin.path)) ?? []
        let versions = entries
            .filter { $0.hasPrefix("ffmpeg@") }
            .sorted { left, right in
                let leftVersion = String(left.dropFirst("ffmpeg@".count))
                let rightVersion = String(right.dropFirst("ffmpeg@".count))
                return VersionCheck.isNewer(leftVersion, than: rightVersion)
            }
        for version in versions {
            let candidate = bin.appendingPathComponent(version, isDirectory: true)
                .appendingPathComponent("ffmpeg")
            if isExecutable(candidate) { return candidate }
        }

        let plain = bin.appendingPathComponent("ffmpeg")
        return isExecutable(plain) ? plain : nil
    }

    static func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}

/// The copy of ffmpeg Voanisa runs.
///
/// It lives in Application Support rather than inside the app bundle: adding a
/// file to a signed bundle invalidates its code signature, and a file in the
/// bundle would be lost on every update.
enum FFmpegLocation {
    /// Points Voanisa at another binary. Tests and the command-line debugging
    /// paths use it instead of the real copy.
    static let environmentKey = "VOANISA_FFMPEG"

    static var libraryDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Voanisa", isDirectory: true)
            .appendingPathComponent("lib", isDirectory: true)
    }

    static var copyURL: URL { libraryDirectory.appendingPathComponent("ffmpeg") }

    /// The binary Voanisa will run, if there is one.
    static var binary: URL? {
        let environment = ProcessInfo.processInfo.environment
        if let override = environment[environmentKey], !override.isEmpty {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            return MacWaveConfiguration.isExecutable(url) ? url : nil
        }
        return MacWaveConfiguration.isExecutable(copyURL) ? copyURL : nil
    }

    static var isInstalled: Bool { binary != nil }

    /// Finds the ffmpeg a tool installed, and only that tool's: silently
    /// substituting another binary would make the wizard's question pointless.
    static func resolve(_ tool: FFmpegTool) -> URL? {
        if tool == .macWave {
            for base in MacWaveConfiguration.baseDirectories() {
                if let binary = MacWaveConfiguration.binary(inBaseDirectory: base) {
                    return binary
                }
            }
            return nil
        }
        return firstExecutable(in: tool.searchPaths)
    }

    static func firstExecutable(in paths: [URL]) -> URL? {
        for path in paths where MacWaveConfiguration.isExecutable(path) {
            return path.resolvingSymlinksInPath()
        }
        return nil
    }

    /// Any ffmpeg on this Mac, offered only so the user can accept it by hand
    /// when the tool they picked has none.
    static func findAnywhere() -> URL? { scanPath() }

    /// Accepts a path the user typed or picked.
    static func resolve(path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        return MacWaveConfiguration.isExecutable(url) ? url.resolvingSymlinksInPath() : nil
    }

    static var searchDirectories: [URL] {
        var directories = [
            "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/sw/bin",
            "/nix/var/nix/profiles/default/bin", "~/.nix-profile/bin",
            "~/.local/bin", "~/bin"
        ].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        directories += path
            .split(separator: ":")
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: String($0), isDirectory: true) }
        return directories
    }

    static func scanPath() -> URL? {
        for directory in searchDirectories {
            let candidate = directory.appendingPathComponent("ffmpeg")
            if MacWaveConfiguration.isExecutable(candidate) {
                return candidate.resolvingSymlinksInPath()
            }
        }
        return nil
    }

    /// Copies a user-supplied ffmpeg into Voanisa's folder.
    static func install(from source: URL, to destination: URL = copyURL) throws {
        let resolved = source.resolvingSymlinksInPath()
        guard MacWaveConfiguration.isExecutable(resolved) else {
            throw FFmpegSetupError.notExecutable
        }
        let target = destination.resolvingSymlinksInPath()
        guard resolved.standardizedFileURL != target.standardizedFileURL else {
            throw FFmpegSetupError.alreadyInPlace
        }

        let manager = FileManager.default
        let directory = destination.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)

        let staging = directory.appendingPathComponent("ffmpeg.copying")
        try? manager.removeItem(at: staging)
        try manager.copyItem(at: resolved, to: staging)
        do {
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.moveItem(at: staging, to: destination)
        } catch {
            try? manager.removeItem(at: staging)
            throw error
        }
    }

    /// Turns WMA support off again by deleting the copy.
    static func removeCopy() {
        try? FileManager.default.removeItem(at: copyURL)
    }
}

enum FFmpegSetupError: LocalizedError, Equatable {
    case notExecutable
    case alreadyInPlace
    case noSource
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .notExecutable:
            return String(localized: "wma.error.notExecutable")
        case .alreadyInPlace:
            return String(localized: "wma.error.alreadyInPlace")
        case .noSource:
            return String(localized: "wma.error.noSource")
        case .runFailed(let message):
            return message
        }
    }
}

/// Paths as the wizard shows them.
///
/// The home directory becomes `~`, which keeps long MacWave and Application
/// Support paths readable in a 560 pt sheet.
enum DisplayPath {
    static func abbreviated(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        let path = url.standardizedFileURL.path
        let homePath = home.standardizedFileURL.path

        if path == homePath { return "~" }
        guard path.hasPrefix(homePath) else { return path }

        let rest = path.dropFirst(homePath.count)
        guard rest.hasPrefix("/") else { return path }
        return "~" + rest
    }
}

/// What `ffmpeg -i` reports about a file. Reading it never decodes audio, so it
/// costs about as much as opening the header.
struct FFmpegMediaInfo: Equatable {
    var duration: Double = 0
    var codec: String?
    var sampleRate: Double = 0
    var channelCount: Int = 0
    var tags: [String: String] = [:]
}

enum FFmpeg {
    /// True when the binary at this path actually starts. A download that
    /// Gatekeeper still quarantines is executable on disk but cannot run.
    static func runs(_ binary: URL) -> Bool {
        guard let result = run(["-hide_banner", "-version"], binary: binary) else { return false }
        return result.status == 0
    }

    /// Header information, or `nil` when ffmpeg is not installed or cannot read the file.
    static func inspect(
        _ url: URL,
        binary: URL? = FFmpegLocation.binary
    ) -> FFmpegMediaInfo? {
        // ffmpeg exits with 1 when no output file is named; the header is still
        // complete on stderr, which is all this needs.
        guard let result = run(["-hide_banner", "-nostdin", "-i", url.path], binary: binary),
              result.output.contains("Input #0") else {
            return nil
        }
        return parse(result.output)
    }

    /// Converts to FLAC, which the portable core decodes in-process.
    static func transcodeToFLAC(
        source: URL,
        destination: URL,
        binary: URL? = FFmpegLocation.binary
    ) throws {
        guard let binary else {
            throw FFmpegSetupError.noSource
        }
        let arguments = [
            "-hide_banner", "-nostdin", "-y",
            "-i", source.path,
            "-map", "0:a:0", "-vn",
            "-map_metadata", "0",
            "-c:a", "flac",
            destination.path
        ]
        guard let result = run(arguments, binary: binary) else {
            throw FFmpegSetupError.runFailed(
                String(format: String(localized: "wma.error.transcode"), source.lastPathComponent)
            )
        }
        guard result.status == 0,
              FileManager.default.fileExists(atPath: destination.path) else {
            throw FFmpegSetupError.runFailed(lastLine(of: result.output))
        }
    }

    static func parse(_ output: String) -> FFmpegMediaInfo {
        var info = FFmpegMediaInfo()
        var insideInput = false
        var insideMetadata = false
        var insideAudio = false

        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("Input #") {
                insideInput = true
                insideMetadata = false
                insideAudio = false
                continue
            }
            guard insideInput else { continue }

            if trimmed.hasPrefix("Stream #") {
                insideAudio = trimmed.contains(": Audio:")
                insideMetadata = false
                if insideAudio, info.codec == nil {
                    info.codec = audioCodec(trimmed)
                    info.sampleRate = firstNumber(before: " Hz", in: trimmed) ?? 0
                    info.channelCount = channelCount(trimmed)
                }
                continue
            }

            if trimmed == "Metadata:" {
                insideMetadata = true
                continue
            }

            if trimmed.hasPrefix("Duration:") {
                if info.duration == 0, let duration = duration(trimmed) {
                    info.duration = duration
                }
                insideMetadata = false
                continue
            }

            if insideMetadata, let colon = trimmed.firstIndex(of: ":") {
                let key = trimmed[trimmed.startIndex ..< colon]
                    .trimmingCharacters(in: .whitespaces)
                    .lowercased()
                let value = trimmed[trimmed.index(after: colon)...]
                    .trimmingCharacters(in: .whitespaces)
                if metadataKeys.contains(key), !value.isEmpty, info.tags[key] == nil {
                    info.tags[key] = value
                }
            }
        }
        return info
    }

    private static let metadataKeys: Set<String> = [
        "title", "artist", "album", "album_artist", "track", "disc"
    ]

    private static func audioCodec(_ line: String) -> String? {
        guard let range = line.range(of: ": Audio: ") else { return nil }
        let rest = line[range.upperBound...]
        let name = rest.prefix { !$0.isWhitespace && $0 != "," }
        return name.isEmpty ? nil : String(name)
    }

    private static func channelCount(_ line: String) -> Int {
        if line.contains(" mono,") || line.hasSuffix(" mono") { return 1 }
        if line.contains(" stereo,") || line.hasSuffix(" stereo") { return 2 }
        if let channels = firstNumber(before: " channels", in: line) { return Int(channels) }
        return 0
    }

    private static func duration(_ line: String) -> Double? {
        guard let range = line.range(of: "Duration: ") else { return nil }
        let value = line[range.upperBound...].prefix { $0 != "," }
        let parts = value.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func firstNumber(before suffix: String, in line: String) -> Double? {
        guard let range = line.range(of: suffix) else { return nil }
        let head = line[..<range.lowerBound]
        let digits = head.reversed().prefix { $0.isNumber || $0 == "." }
        return Double(String(digits.reversed()))
    }

    private static func lastLine(of output: String) -> String {
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.last ?? String(localized: "wma.error.transcodeGeneric")
    }

    struct Output {
        var status: Int32
        var output: String
    }

    /// Runs ffmpeg and returns its combined output. ffmpeg writes everything to
    /// stderr, so stdout is discarded.
    static func run(_ arguments: [String], binary: URL? = FFmpegLocation.binary) -> Output? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Output(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
    }
}
