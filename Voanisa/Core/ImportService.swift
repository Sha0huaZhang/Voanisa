import AVFoundation
import CryptoKit
import Foundation

struct ImportCandidate: Identifiable, Sendable {
    let id: UUID
    let sourceURL: URL
    let probe: AudioProbeResult
    var title: String
    var artist: String = ""
    var album: String = ""
    var albumArtist: String = ""
    var trackNumber: Int?
    var discNumber: Int?
    var coverJPEG: Data?
    var originalCoverData: Data?
    var originalCoverExtension: String?
    var error: String?

    init(sourceURL: URL, probe: AudioProbeResult, title: String) {
        self.id = UUID()
        self.sourceURL = sourceURL
        self.probe = probe
        self.title = title
        self.coverJPEG = nil
        self.originalCoverData = nil
        self.originalCoverExtension = nil
        self.error = probe.isSupported ? nil : (probe.failureReason ?? String(localized: "probe.unsupportedGeneric"))
    }
}

struct ImportOutcome: Sendable {
    var tracks: [Track]
    var skippedDuplicates: Int
    var failures: [String]
    var failedCandidateIDs: [UUID] = []
    var cancelled: Bool = false
}

enum ImportError: LocalizedError {
    case noAudioTrack
    case stagingFailed
    case exportUnavailable
    case exportFailed(String)
    case emptyTitle(String)

    var errorDescription: String? {
        switch self {
        case .noAudioTrack:
            return String(localized: "error.noAudioTrack")
        case .stagingFailed:
            return String(localized: "error.staging")
        case .exportUnavailable:
            return String(localized: "error.export")
        case .exportFailed(let message):
            return message
        case .emptyTitle(let name):
            return String(format: String(localized: "error.emptyTitle"), name)
        }
    }
}

/// What the importer is doing, so the sheet can say it out loud.
///
/// Copying files can take minutes on a large selection; writing the finished
/// tracks into SQLite and the JSON snapshot is a separate, usually shorter
/// step that has no per-file progress of its own.
enum ImportPhase: Sendable, Equatable {
    case processing
    case saving
}

/// Copies selected files into the library and records them.
enum ImportService {
    /// Expands selected files and folders. Header sniffing filters out images,
    /// text files and other non-audio documents without trusting extensions.
    static func expand(urls: [URL]) -> [URL] {
        var result: [URL] = []
        var seen = Set<String>()

        func append(_ url: URL) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted else { return }
            result.append(url)
        }

        for url in urls {
            let values = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .isPackageKey, .isRegularFileKey]
            )
            if values?.isDirectory == true, values?.isPackage != true {
                let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isPackageKey]
                guard let enumerator = FileManager.default.enumerator(
                    at: url,
                    includingPropertiesForKeys: keys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                ) else { continue }

                for case let fileURL as URL in enumerator {
                    let fileValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
                    guard fileValues?.isRegularFile == true else { continue }
                    // Header sniffing still decides; this only avoids opening
                    // every photo and document in a large folder.
                    guard Self.looksLikeAudio(fileURL) else { continue }
                    append(fileURL)
                }
            } else if values?.isRegularFile == true {
                // A file the user picked explicitly is always inspected.
                append(url)
            }
        }

        return result
    }

    private static func looksLikeAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }

    private static let audioExtensions: Set<String> = [
        "mp3", "mp2", "mp1", "m4a", "m4b", "m4r", "aac", "alac",
        "flac", "wav", "wave", "aiff", "aif", "aifc", "caf",
        "mp4", "mov", "m4v", "ogg", "oga", "opus", "wv", "ape",
        "mka", "mkv", "webm", "wma", "dsf", "dff"
    ]

    /// Probes files and reads their tags, a few at a time.
    ///
    /// AVFoundation spends tens of milliseconds per asset just opening it, so
    /// a serial pass over a large folder looks frozen. The work is I/O bound,
    /// which is why a small task group beats any single-threaded rewrite.
    static func prepare(
        urls: [URL],
        onProgress: ((Int, Int) -> Void)? = nil
    ) async -> [ImportCandidate] {
        let files = expand(urls: urls)
        guard !files.isEmpty else { return [] }

        var candidates = [ImportCandidate?](repeating: nil, count: files.count)
        let reportEvery = max(1, files.count / 200)
        var processed = 0

        await withTaskGroup(of: (Int, ImportCandidate?).self) { group in
            var next = 0
            let limit = min(8, files.count)

            while next < limit {
                let index = next
                let url = files[index]
                next += 1
                group.addTask { (index, await makeCandidate(for: url)) }
            }

            for await (index, candidate) in group {
                candidates[index] = candidate
                processed += 1
                if processed == files.count || processed % reportEvery == 0 {
                    onProgress?(processed, files.count)
                }

                if next < files.count {
                    let index = next
                    let url = files[index]
                    next += 1
                    group.addTask { (index, await makeCandidate(for: url)) }
                }
            }
        }

        onProgress?(files.count, files.count)
        return candidates.compactMap { $0 }
    }

    private static func makeCandidate(for url: URL) async -> ImportCandidate? {
        // The folder walk filters by extension; the header still has the last
        // word, and is checked here so the eight-way group pays for it in
        // parallel rather than during enumeration.
        guard AudioProbe.quickContainer(for: url) != .unknown else { return nil }

        // One asset per file: probing and tag reading share the same parse.
        let asset = AVURLAsset(url: url)
        let probe = await AudioProbe.probe(url: url, asset: asset)
        var embedded = probe.isSupported
            ? await AudioMetadataReader.read(url: url, asset: asset)
            : EmbeddedMetadata()

        // Ogg, Opus and the other portable formats have no AVFoundation
        // metadata, so the Rust core supplies the basics.
        if !probe.container.isNative, let tags = RustCore.tags(url: url) {
            embedded.title = embedded.title ?? tags.title
            embedded.artist = embedded.artist ?? tags.artist
            embedded.album = embedded.album ?? tags.album
            embedded.albumArtist = embedded.albumArtist ?? tags.albumArtist
            embedded.trackNumber = embedded.trackNumber ?? tags.trackNumber
            embedded.discNumber = embedded.discNumber ?? tags.discNumber
        }

        let fallbackTitle = url.deletingPathExtension().lastPathComponent
        var candidate = ImportCandidate(
            sourceURL: url,
            probe: probe,
            title: embedded.title ?? fallbackTitle
        )
        candidate.artist = embedded.artist ?? ""
        candidate.album = embedded.album ?? ""
        candidate.albumArtist = embedded.albumArtist ?? ""
        candidate.trackNumber = embedded.trackNumber
        candidate.discNumber = embedded.discNumber

        if let artwork = embedded.artwork,
           let image = CoverRenderer.loadOrientedImage(data: artwork),
           let rendered = CoverRenderer.centeredSquareCoverJPEG(from: image) {
            candidate.coverJPEG = rendered
            candidate.originalCoverData = artwork
            candidate.originalCoverExtension = CoverRenderer.imageFileExtension(
                for: artwork
            )
        }

        if embedded.title != nil || embedded.artist != nil || embedded.album != nil {
            Diagnostics.log("读取内嵌标签 \(url.lastPathComponent)")
        }
        return candidate
    }

    static func commit(
        candidates: [ImportCandidate],
        existing: [Track],
        skipDuplicates: Bool = true,
        rootURL: URL = LibraryLocation.rootURL,
        onPhase: ((ImportPhase) -> Void)? = nil,
        onProgress: ((Int, Int) -> Void)? = nil
    ) async throws -> ImportOutcome {
        try LibraryLocation.ensureDirectories(rootURL: rootURL)
        LibraryLocation.cleanStaging(rootURL: rootURL)

        let mediaURL = rootURL.appendingPathComponent("Media", isDirectory: true)
        let coversURL = rootURL.appendingPathComponent("Covers", isDirectory: true)
        let renderedCoversURL = coversURL.appendingPathComponent(
            "Rendered",
            isDirectory: true
        )
        let originalCoversURL = coversURL.appendingPathComponent(
            "Originals",
            isDirectory: true
        )
        let stagingURL = rootURL.appendingPathComponent(".staging", isDirectory: true)
        let databaseURL = rootURL.appendingPathComponent("library.sqlite")
        let jsonURL = rootURL.appendingPathComponent("library.json")

        var existingHashes = Set(existing.map(\.contentHash))
        var newTracks: [Track] = []
        var failures: [String] = []
        var failedCandidateIDs: [UUID] = []
        var skipped = 0
        var cancelled = false
        let total = candidates.count

        onPhase?(.processing)

        // One callback per file would mean one main-actor hop and one SwiftUI
        // update per file; roughly 200 updates keep large imports responsive.
        let reportEvery = max(1, total / 200)
        var processed = 0

        for (index, candidate) in candidates.enumerated() {
            if Task.isCancelled {
                cancelled = true
                break
            }
            processed = index + 1
            defer {
                if processed == total || processed % reportEvery == 0 {
                    onProgress?(processed, total)
                }
            }

            if let error = candidate.error {
                failures.append("\(candidate.sourceURL.lastPathComponent)：\(error)")
                failedCandidateIDs.append(candidate.id)
                continue
            }

            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                failures.append(ImportError.emptyTitle(candidate.sourceURL.lastPathComponent).localizedDescription)
                failedCandidateIDs.append(candidate.id)
                continue
            }

            do {
                let hash = try sha256(of: candidate.sourceURL)
                if skipDuplicates, existingHashes.contains(hash) {
                    skipped += 1
                    Diagnostics.log("跳过重复文件 \(candidate.sourceURL.lastPathComponent)")
                    continue
                }

                let id = UUID()
                let needsExtraction = candidate.probe.hasVideo
                    || candidate.probe.container == .mp4
                    || candidate.probe.container == .mov

                let stagedURL: URL
                let fileExtension: String
                if needsExtraction {
                    stagedURL = try await extractAudio(
                        from: candidate.sourceURL,
                        stagingURL: stagingURL
                    )
                    fileExtension = "m4a"
                } else {
                    fileExtension = preferredExtension(for: candidate)
                    let destination = stagingURL
                        .appendingPathComponent("\(id.uuidString).\(fileExtension)")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: candidate.sourceURL, to: destination)
                    stagedURL = destination
                }

                let fileName = "\(id.uuidString).\(fileExtension)"
                let finalURL = mediaURL.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)

                var coverFileName: String?
                if let cover = candidate.coverJPEG {
                    let coverName = "\(id.uuidString).jpg"
                    try cover.write(
                        to: renderedCoversURL.appendingPathComponent(coverName),
                        options: .atomic
                    )
                    coverFileName = coverName
                }
                if let original = candidate.originalCoverData {
                    let ext = candidate.originalCoverExtension ?? "img"
                    let originalName = "\(id.uuidString).\(ext)"
                    do {
                        try original.write(
                            to: originalCoversURL.appendingPathComponent(originalName),
                            options: .atomic
                        )
                    } catch {
                        Diagnostics.error(error.localizedDescription, context: "import.originalCover")
                    }
                }

                let storedFormat = needsExtraction ? "M4A · AAC" : candidate.probe.formatDescription
                let track = Track(
                    id: id,
                    title: title,
                    artist: candidate.artist.trimmingCharacters(in: .whitespacesAndNewlines),
                    album: candidate.album.trimmingCharacters(in: .whitespacesAndNewlines),
                    duration: candidate.probe.duration,
                    fileName: fileName,
                    coverFileName: coverFileName,
                    format: storedFormat,
                    contentHash: hash,
                    dateAdded: Date(),
                    albumArtist: candidate.albumArtist
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                    trackNumber: candidate.trackNumber,
                    discNumber: candidate.discNumber
                )
                newTracks.append(track)
                existingHashes.insert(hash)
                Diagnostics.log("导入《\(title)》，格式 \(candidate.probe.formatDescription)")
            } catch {
                if Task.isCancelled {
                    cancelled = true
                    break
                }
                failures.append("\(candidate.sourceURL.lastPathComponent)：\(error.localizedDescription)")
                failedCandidateIDs.append(candidate.id)
                Diagnostics.log("导入失败 \(candidate.sourceURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        // Report the real stopping point even when the loop ended early.
        onProgress?(processed, total)

        if !newTracks.isEmpty {
            onPhase?(.saving)
            try LibraryStore.save(
                existing + newTracks,
                databaseURL: databaseURL,
                jsonURL: jsonURL
            )
        }
        LibraryLocation.cleanStaging(rootURL: rootURL)

        if cancelled {
            Diagnostics.log("导入已取消：已导入 \(newTracks.count) 首")
        }

        return ImportOutcome(
            tracks: newTracks,
            skippedDuplicates: skipped,
            failures: failures,
            failedCandidateIDs: failedCandidateIDs,
            cancelled: cancelled
        )
    }

    // MARK: - Helpers

    private static func preferredExtension(for candidate: ImportCandidate) -> String {
        switch candidate.probe.container {
        case .mp3: return "mp3"
        case .aac: return "aac"
        case .m4a: return "m4a"
        case .flac: return "flac"
        case .wav: return "wav"
        case .aiff: return "aiff"
        case .caf: return "caf"
        default:
            let ext = candidate.sourceURL.pathExtension.lowercased()
            return ext.isEmpty ? "audio" : ext
        }
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let data = try handle.read(upToCount: 1 << 20), !data.isEmpty else { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// MP4/MOV files are copied as audio-only M4A so the library never contains
    /// video files and the “one audio file = one song” model stays intact.
    private static func extractAudio(
        from url: URL,
        stagingURL: URL
    ) async throws -> URL {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError.noAudioTrack
        }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ImportError.exportUnavailable
        }
        try compositionTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration),
            of: audioTrack,
            at: .zero
        )

        let output = stagingURL
            .appendingPathComponent("\(UUID().uuidString).m4a")

        // Copy the existing audio track when the codec is already MP4
        // compatible (the usual case for camera videos). Re-encoding is only a
        // fallback: it turns a copy into minutes of AAC encoding.
        if let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetPassthrough
        ) {
            do {
                try await runExport(session, to: output, timeout: 120)
                return output
            } catch {
                Diagnostics.log(
                    "直通导出失败，改用 AAC 重编码：\(error.localizedDescription)"
                )
                try? FileManager.default.removeItem(at: output)
            }
        }

        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ImportError.exportUnavailable
        }

        try await runExport(session, to: output, timeout: 300)
        return output
    }

    /// Exports with a deadline and cancellation support.
    ///
    /// AVFoundation occasionally never resumes an export. Without this, the
    /// sheet stayed disabled in its “importing” state forever, which looked
    /// like a frozen app; a timeout turns it into a per-file failure instead.
    private static func runExport(
        _ session: AVAssetExportSession,
        to output: URL,
        timeout: TimeInterval
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    try await session.export(to: output, as: .m4a)
                } onCancel: {
                    session.cancelExport()
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                session.cancelExport()
                throw ImportError.exportFailed(
                    String(localized: "error.exportTimeout")
                )
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}
