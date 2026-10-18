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
        return .unknown
    }

    static func probe(url: URL, asset: AVURLAsset? = nil) async -> AudioProbeResult {
        let rust = RustCore.probe(url: url)
        let headerContainer: AudioContainer
        if let payload = rust, payload.recognized,
           let container = AudioContainer(rawValue: payload.container) {
            headerContainer = container
        } else {
            // The Rust probe validates real frame chains, so an unrecognized
            // signature means this is not audio at all. Letting AVFoundation
            // guess here is how stray binaries once ended up in the library.
            return AudioProbeResult(
                container: .unknown,
                codec: nil,
                duration: 0,
                hasVideo: false,
                sampleRate: 0,
                channelCount: 0,
                isSupported: false,
                failureReason: String(localized: "probe.unsupportedGeneric")
            )
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

        let asset = asset ?? AVURLAsset(url: url)
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
