import AVFoundation
import Foundation

/// Metadata read from the audio container itself.
struct EmbeddedMetadata: Sendable {
    var title: String? = nil
    var artist: String? = nil
    var album: String? = nil
    var albumArtist: String? = nil
    var trackNumber: Int? = nil
    var discNumber: Int? = nil
    var artwork: Data? = nil
}

/// Reads embedded tags and artwork with AVFoundation.
///
/// The importer uses this to pre-fill the sheet. Anything missing falls back to
/// the file name and the default artwork, so a malformed tag never blocks an
/// import.
enum AudioMetadataReader {
    static func read(url: URL) async -> EmbeddedMetadata {
        let asset = AVURLAsset(url: url)
        do {
            let items = try await asset.load(.metadata)
            return await parse(items)
        } catch {
            Diagnostics.error(error.localizedDescription, context: "metadata.read")
            return EmbeddedMetadata()
        }
    }

    private static func parse(_ items: [AVMetadataItem]) async -> EmbeddedMetadata {
        var metadata = EmbeddedMetadata()

        for item in items {
            if item.commonKey?.rawValue == AVMetadataKey.commonKeyTitle.rawValue {
                metadata.title = clean(await stringValue(of: item))
            } else if item.commonKey?.rawValue == AVMetadataKey.commonKeyArtist.rawValue {
                metadata.artist = clean(await stringValue(of: item))
            } else if item.commonKey?.rawValue == AVMetadataKey.commonKeyAlbumName.rawValue {
                metadata.album = clean(await stringValue(of: item))
            } else if item.commonKey?.rawValue == AVMetadataKey.commonKeyArtwork.rawValue {
                metadata.artwork = await dataValue(of: item)
            }

            guard let identifier = item.identifier?.rawValue.lowercased() else { continue }

            if isAlbumArtist(identifier) {
                metadata.albumArtist = clean(await stringValue(of: item))
            } else if isTrackNumber(identifier) {
                metadata.trackNumber = await number(from: item)
            } else if isDiscNumber(identifier) {
                metadata.discNumber = await number(from: item)
            } else if isArtwork(identifier), metadata.artwork == nil {
                metadata.artwork = await dataValue(of: item)
            } else if metadata.title == nil, identifier.hasSuffix("/%a9nam") {
                metadata.title = clean(await stringValue(of: item))
            } else if metadata.artist == nil, identifier.hasSuffix("/%a9art") {
                metadata.artist = clean(await stringValue(of: item))
            } else if metadata.album == nil, identifier.hasSuffix("/%a9alb") {
                metadata.album = clean(await stringValue(of: item))
            }
        }

        return metadata
    }

    private static func stringValue(of item: AVMetadataItem) async -> String? {
        (try? await item.load(.stringValue)) ?? nil
    }

    private static func dataValue(of item: AVMetadataItem) async -> Data? {
        (try? await item.load(.dataValue)) ?? nil
    }

    private static func clean(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private static func isAlbumArtist(_ identifier: String) -> Bool {
        identifier == "itsk/aart"
            || identifier.contains("albumartist")
            || identifier.contains("album_artist")
            || identifier.hasSuffix("/tpe2")
    }

    private static func isTrackNumber(_ identifier: String) -> Bool {
        identifier == "itsk/trkn"
            || identifier.contains("tracknumber")
            || identifier.hasSuffix("/trck")
    }

    private static func isDiscNumber(_ identifier: String) -> Bool {
        identifier == "itsk/disk"
            || identifier.contains("discnumber")
            || identifier.hasSuffix("/tpos")
    }

    private static func isArtwork(_ identifier: String) -> Bool {
        identifier == "itsk/covr"
            || identifier.contains("artwork")
            || identifier.contains("attachedpicture")
            || identifier.hasSuffix("/apic")
    }

    private static func number(from item: AVMetadataItem) async -> Int? {
        if let string = await stringValue(of: item),
           let value = leadingInteger(in: string) {
            return value
        }
        if let data = await dataValue(of: item) {
            return integer(from: data)
        }
        return nil
    }

    private static func leadingInteger(in value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    /// iTunes stores track/disc numbers as two big-endian 16-bit values after
    /// two reserved bytes; ID3 stores them as strings and is handled above.
    private static func integer(from data: Data) -> Int? {
        if data.count >= 4 {
            let value = UInt16(data[2]) << 8 | UInt16(data[3])
            if value > 0 { return Int(value) }
        }
        if data.count >= 2 {
            let value = UInt16(data[0]) << 8 | UInt16(data[1])
            if value > 0 { return Int(value) }
        }
        return nil
    }
}
