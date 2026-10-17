import Foundation

/// One audio file is one song in Voanisa.
///
/// The database stores only the relative file name; the library folder can be
/// moved or backed up as a whole without rewriting absolute paths.
struct Track: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var fileName: String
    var coverFileName: String?
    var format: String
    var contentHash: String
    var dateAdded: Date

    var albumArtist: String = ""
    var trackNumber: Int?
    var discNumber: Int?
    var source: String = "local"
    var musicPersistentID: String?

    var displayArtist: String {
        let value = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty { return value }

        let albumValue = albumArtist.trimmingCharacters(in: .whitespacesAndNewlines)
        return albumValue.isEmpty ? String(localized: "track.unknownArtist") : albumValue
    }

    init(
        id: UUID,
        title: String,
        artist: String,
        album: String,
        duration: Double,
        fileName: String,
        coverFileName: String?,
        format: String,
        contentHash: String,
        dateAdded: Date,
        albumArtist: String = "",
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        source: String = "local",
        musicPersistentID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.fileName = fileName
        self.coverFileName = coverFileName
        self.format = format
        self.contentHash = contentHash
        self.dateAdded = dateAdded
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.source = source
        self.musicPersistentID = musicPersistentID
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, fileName, coverFileName
        case format, contentHash, dateAdded
        case albumArtist, trackNumber, discNumber, source, musicPersistentID
    }

    /// Decodes older snapshots that only contain the prototype fields.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        artist = try container.decodeIfPresent(String.self, forKey: .artist) ?? ""
        album = try container.decodeIfPresent(String.self, forKey: .album) ?? ""
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        fileName = try container.decode(String.self, forKey: .fileName)
        coverFileName = try container.decodeIfPresent(String.self, forKey: .coverFileName)
        format = try container.decodeIfPresent(String.self, forKey: .format) ?? ""
        contentHash = try container.decodeIfPresent(String.self, forKey: .contentHash) ?? ""
        dateAdded = try container.decodeIfPresent(Date.self, forKey: .dateAdded)
            ?? Date(timeIntervalSince1970: 0)
        albumArtist = try container.decodeIfPresent(String.self, forKey: .albumArtist) ?? ""
        trackNumber = try container.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try container.decodeIfPresent(Int.self, forKey: .discNumber)
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? "local"
        musicPersistentID = try container.decodeIfPresent(
            String.self,
            forKey: .musicPersistentID
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(album, forKey: .album)
        try container.encode(duration, forKey: .duration)
        try container.encode(fileName, forKey: .fileName)
        try container.encodeIfPresent(coverFileName, forKey: .coverFileName)
        try container.encode(format, forKey: .format)
        try container.encode(contentHash, forKey: .contentHash)
        try container.encode(dateAdded, forKey: .dateAdded)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encodeIfPresent(trackNumber, forKey: .trackNumber)
        try container.encodeIfPresent(discNumber, forKey: .discNumber)
        try container.encode(source, forKey: .source)
        try container.encodeIfPresent(musicPersistentID, forKey: .musicPersistentID)
    }
}
