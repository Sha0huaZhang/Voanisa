import AVFoundation
import CoreMedia
import Foundation

/// Container detected from the file header, never from the extension.
enum AudioContainer: String, Sendable {
    case mp3
    case aac
    case m4a
    case mp4
    case mov
    case flac
    case wav
    case aiff
    case caf
    case ogg
    case opus
    case mkv
    case webm
    case wma
    case ape
    case wavpack
    case dsf
    case dff
    case unknown

    var displayName: String {
        switch self {
        case .mp3: return "MP3"
        case .aac: return "AAC"
        case .m4a: return "M4A"
        case .mp4: return "MP4"
        case .mov: return "MOV"
        case .flac: return "FLAC"
        case .wav: return "WAV"
        case .aiff: return "AIFF"
        case .caf: return "CAF"
        case .ogg: return "OGG Vorbis"
        case .opus: return "Opus"
        case .mkv: return "Matroska"
        case .webm: return "WebM"
        case .wma: return "WMA"
        case .ape: return "APE"
        case .wavpack: return "WavPack"
        case .dsf: return "DSF"
        case .dff: return "DFF"
        case .unknown: return String(localized: "format.unknown")
        }
    }

    var isNative: Bool {
        switch self {
        case .mp3, .aac, .m4a, .mp4, .mov, .flac, .wav, .aiff, .caf:
            return true
        default:
            return false
        }
    }
}

struct AudioProbeResult: Sendable {
    var container: AudioContainer
    var codec: String?
    var duration: Double
    var hasVideo: Bool
    var sampleRate: Double
    var channelCount: Int
    var isSupported: Bool
    var failureReason: String?

    var formatDescription: String {
        var parts: [String] = [container.displayName]
        if let codec, !codec.isEmpty { parts.append(codec.uppercased()) }
        return parts.joined(separator: " · ")
    }
}

/// Header-first detection.
///
/// The extension is never consulted. macOS's AVFoundation is used to confirm
/// that there is a real audio track, read its codec and duration, and detect
/// video tracks that must be stripped during import.
enum AudioProbe {
    static func quickContainer(for url: URL) -> AudioContainer {
        if let payload = RustCore.probe(url: url),
           payload.recognized,
           let container = AudioContainer(rawValue: payload.container) {
            return container
        }
        return detectContainer(in: readHeader(url))
    }

    static func probe(url: URL) async -> AudioProbeResult {
        let rust = RustCore.probe(url: url)
        let headerContainer: AudioContainer
        if let payload = rust, payload.recognized,
           let container = AudioContainer(rawValue: payload.container) {
            headerContainer = container
        } else {
            headerContainer = detectContainer(in: readHeader(url))
        }

        switch headerContainer {
        case .ogg, .opus, .wavpack, .ape:
            // The Rust core decodes these in-process: Symphonia and
            // `opus-pure` for Ogg, `wavicle` for WavPack, `ape-decoder` for
            // Monkey's Audio.
            if let stream = RustCore.decoderInfo(url: url) {
                return AudioProbeResult(
                    container: headerContainer,
                    codec: rust?.codec ?? stream.codec,
                    duration: stream.durationSeconds,
                    hasVideo: false,
                    sampleRate: stream.sampleRate,
                    channelCount: stream.channels,
                    isSupported: true,
                    failureReason: nil
                )
            }
            return AudioProbeResult(
                container: headerContainer,
                codec: rust?.codec,
                duration: 0,
                hasVideo: false,
                sampleRate: 0,
                channelCount: 0,
                isSupported: false,
                failureReason: String(
                    format: String(localized: "probe.unsupported"),
                    headerContainer.displayName
                )
            )
        case .mkv, .webm, .wma, .dsf, .dff:
            // Recognised by signature but not decoded yet.
            return AudioProbeResult(
                container: headerContainer,
                codec: rust?.codec,
                duration: 0,
                hasVideo: false,
                sampleRate: 0,
                channelCount: 0,
                isSupported: false,
                failureReason: String(
                    format: String(localized: "probe.unsupported"),
                    headerContainer.displayName
                )
            )
        default:
            break
        }

        let asset = AVURLAsset(url: url)
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)

            guard let audioTrack = audioTracks.first else {
                return AudioProbeResult(
                    container: headerContainer,
                    codec: nil,
                    duration: 0,
                    hasVideo: !videoTracks.isEmpty,
                    sampleRate: 0,
                    channelCount: 0,
                    isSupported: false,
                    failureReason: String(localized: "probe.noAudioTrack")
                )
            }

            let rawDuration = (try? await asset.load(.duration).seconds) ?? 0
            let duration = rawDuration.isFinite && rawDuration > 0 ? rawDuration : 0

            let descriptions = (try? await audioTrack.load(.formatDescriptions)) ?? []
            let first = descriptions.first
            let codec = first.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) } ?? rust?.codec
            let stream = first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            let sampleRate = stream?.mSampleRate ?? 0
            let channels = Int(stream?.mChannelsPerFrame ?? 0)

            // Audio-only ISO BMFF files are surfaced as M4A, which makes the
            // “one audio file = one song” rule obvious in the UI.
            let container: AudioContainer
            if (headerContainer == .mp4 || headerContainer == .mov) && videoTracks.isEmpty {
                container = .m4a
            } else {
                container = headerContainer
            }

            return AudioProbeResult(
                container: container,
                codec: codec,
                duration: duration,
                hasVideo: !videoTracks.isEmpty,
                sampleRate: sampleRate,
                channelCount: channels,
                isSupported: true,
                failureReason: nil
            )
        } catch {
            return AudioProbeResult(
                container: headerContainer,
                codec: nil,
                duration: 0,
                hasVideo: false,
                sampleRate: 0,
                channelCount: 0,
                isSupported: false,
                failureReason: error.localizedDescription
            )
        }
    }

    // MARK: - Header parsing

    // MP3 files often carry large embedded artwork, so the first frame can sit
    // well past 64 KB. One megabyte still keeps probing cheap.
    private static func readHeader(_ url: URL, maxBytes: Int = 1 << 20) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: maxBytes)) ?? Data()
    }

    private static func detectContainer(in data: Data) -> AudioContainer {
        guard data.count >= 12 else { return .unknown }

        if starts(with: data, offset: 0, ascii: "fLaC") { return .flac }
        if starts(with: data, offset: 0, ascii: "OggS") {
            if data.range(of: Data("OpusHead".utf8)) != nil { return .opus }
            return .ogg
        }
        if starts(with: data, offset: 0, ascii: "RIFF") {
            if starts(with: data, offset: 8, ascii: "WAVE") { return .wav }
            if starts(with: data, offset: 8, ascii: "AVI ") { return .unknown }
        }
        if starts(with: data, offset: 0, ascii: "FORM") {
            if starts(with: data, offset: 8, ascii: "AIFF") || starts(with: data, offset: 8, ascii: "AIFC") {
                return .aiff
            }
        }
        if starts(with: data, offset: 0, ascii: "caff") { return .caf }
        if starts(with: data, offset: 4, ascii: "ftyp") {
            let brand = asciiString(data, offset: 8, length: 4)
            switch brand {
            case "qt  ":
                return .mov
            case "M4A ", "M4B ", "M4P ", "M4R ":
                return .m4a
            default:
                return .mp4
            }
        }
        if starts(with: data, offset: 0, ascii: "MAC ") { return .ape }
        if starts(with: data, offset: 0, ascii: "wvpk") { return .wavpack }
        if starts(with: data, offset: 0, ascii: "DSD ") { return .dsf }
        if starts(with: data, offset: 0, ascii: "FRM8") { return .dff }
        if data.count >= 16, data[0] == 0x30, data[1] == 0x26, data[2] == 0xB2, data[3] == 0x75,
           data[4] == 0x8E, data[5] == 0x66, data[6] == 0xCF, data[7] == 0x11 {
            return .wma
        }
        if data.count >= 4, data[0] == 0x1A, data[1] == 0x45, data[2] == 0xDF, data[3] == 0xA3 {
            if data.range(of: Data("webm".utf8)) != nil { return .webm }
            if data.range(of: Data("matroska".utf8)) != nil { return .mkv }
            return .mkv
        }
        if looksLikeADTS(data) { return .aac }
        if looksLikeMP3(data) { return .mp3 }

        return .unknown
    }

    private static func starts(with data: Data, offset: Int, ascii: String) -> Bool {
        let bytes = Array(ascii.utf8)
        guard offset >= 0, offset + bytes.count <= data.count else { return false }
        for (index, byte) in bytes.enumerated() where data[offset + index] != byte {
            return false
        }
        return true
    }

    private static func asciiString(_ data: Data, offset: Int, length: Int) -> String {
        guard offset >= 0, offset + length <= data.count else { return "" }
        return String(bytes: data[offset ..< offset + length], encoding: .ascii) ?? ""
    }

    private static func looksLikeADTS(_ data: Data) -> Bool {
        guard data.count >= 2 else { return false }
        return data[0] == 0xFF && (data[1] & 0xF6) == 0xF0
    }

    private static func looksLikeMP3(_ data: Data) -> Bool {
        var offset = 0
        if starts(with: data, offset: 0, ascii: "ID3"), data.count >= 10 {
            let size = (Int(data[6] & 0x7F) << 21)
                | (Int(data[7] & 0x7F) << 14)
                | (Int(data[8] & 0x7F) << 7)
                | Int(data[9] & 0x7F)
            offset = 10 + size
        }

        var index = offset
        while index + 1 < data.count {
            if data[index] == 0xFF, (data[index + 1] & 0xE0) == 0xE0 {
                let version = (data[index + 1] >> 3) & 0x03
                let layer = (data[index + 1] >> 1) & 0x03
                if version != 0x01, layer != 0x00 { return true }
            }
            index += 1
        }
        return false
    }

    private static func fourCC(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? String(format: "%08X", code)
    }
}
