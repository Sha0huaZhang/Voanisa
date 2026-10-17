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
                    guard AudioProbe.quickContainer(for: fileURL) != .unknown else { continue }
                    append(fileURL)
                }
            } else if values?.isRegularFile == true {
                guard AudioProbe.quickContainer(for: url) != .unknown else { continue }
                append(url)
            }
        }

        return result
    }

    static func prepare(urls: [URL]) async -> [ImportCandidate] {
        let files = expand(urls: urls)
        var candidates: [ImportCandidate] = []
        candidates.reserveCapacity(files.count)

        for url in files {
            let probe = await AudioProbe.probe(url: url)
            let embedded = probe.isSupported
                ? await AudioMetadataReader.read(url: url)
                : EmbeddedMetadata()

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
            candidates.append(candidate)
        }
        return candidates
    }

    static func commit(candidates: [ImportCandidate], existing: [Track]) async throws -> ImportOutcome {
        try LibraryLocation.ensureDirectories()
        LibraryLocation.cleanStaging()

        var existingHashes = Set(existing.map(\.contentHash))
        var newTracks: [Track] = []
        var failures: [String] = []
        var skipped = 0

        for candidate in candidates {
            if let error = candidate.error {
                failures.append("\(candidate.sourceURL.lastPathComponent)：\(error)")
                continue
            }

            let title = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                failures.append(ImportError.emptyTitle(candidate.sourceURL.lastPathComponent).localizedDescription)
                continue
            }

            do {
                let hash = try sha256(of: candidate.sourceURL)
                guard !existingHashes.contains(hash) else {
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
                    stagedURL = try await extractAudio(from: candidate.sourceURL)
                    fileExtension = "m4a"
                } else {
                    fileExtension = preferredExtension(for: candidate)
                    let destination = LibraryLocation.stagingURL
                        .appendingPathComponent("\(id.uuidString).\(fileExtension)")
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.copyItem(at: candidate.sourceURL, to: destination)
                    stagedURL = destination
                }

                let fileName = "\(id.uuidString).\(fileExtension)"
                let finalURL = LibraryLocation.mediaURL(for: fileName)
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    try FileManager.default.removeItem(at: finalURL)
                }
                try FileManager.default.moveItem(at: stagedURL, to: finalURL)

                var coverFileName: String?
                if let cover = candidate.coverJPEG {
                    let coverName = "\(id.uuidString).jpg"
                    try cover.write(to: LibraryLocation.coverURL(for: coverName), options: .atomic)
                    coverFileName = coverName
                }
                if let original = candidate.originalCoverData {
                    let ext = candidate.originalCoverExtension ?? "img"
                    let originalName = "\(id.uuidString).\(ext)"
                    do {
                        try original.write(
                            to: LibraryLocation.originalCoversURL.appendingPathComponent(originalName),
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
                failures.append("\(candidate.sourceURL.lastPathComponent)：\(error.localizedDescription)")
                Diagnostics.log("导入失败 \(candidate.sourceURL.lastPathComponent)：\(error.localizedDescription)")
            }
        }

        if !newTracks.isEmpty {
            try LibraryStore.save(existing + newTracks)
        }
        LibraryLocation.cleanStaging()

        return ImportOutcome(tracks: newTracks, skippedDuplicates: skipped, failures: failures)
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
    private static func extractAudio(from url: URL) async throws -> URL {
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

        let output = LibraryLocation.stagingURL
            .appendingPathComponent("\(UUID().uuidString).m4a")
        guard let session = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw ImportError.exportUnavailable
        }

        try await session.export(to: output, as: .m4a)
        return output
    }
}
