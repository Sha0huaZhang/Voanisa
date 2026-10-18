import Foundation

struct RustProbePayload: Decodable {
    let container: String
    let codec: String?
    let recognized: Bool
    let error: String?
}

/// Thin Swift wrapper around the portable Rust core.
///
/// The C ABI exchanges JSON strings instead of structs, so layout changes in
/// Rust never break the Swift side.
enum RustCore {
    static var version: String {
        String(cString: voanisa_core_version())
    }

    static func probe(url: URL) -> RustProbePayload? {
        guard let pointer = url.path.withCString({ voanisa_probe_json($0) }) else {
            return nil
        }
        defer { voanisa_string_free(pointer) }

        let json = String(cString: pointer)
        return try? JSONDecoder().decode(RustProbePayload.self, from: Data(json.utf8))
    }

    /// Tags for containers AVFoundation cannot read, such as Ogg and Opus.
    static func tags(url: URL) -> RustTags? {
        let result: Result<RustTags, RustBridgeError> = url.path.withCString { pointer in
            decodeEnvelope(voanisa_tags_json(pointer))
        }
        return try? result.get()
    }

    /// Stream properties read from headers only, so probing never decodes a
    /// whole WavPack or APE file.
    static func decoderInfo(url: URL) -> RustDecoderInfo? {
        let result: Result<RustDecoderInfo, RustBridgeError> = url.path.withCString { pointer in
            decodeEnvelope(voanisa_stream_info_json(pointer))
        }
        return try? result.get()
    }

    /// Why `voanisa_decoder_open` would fail for this file.
    static func decoderOpenError(url: URL) -> String? {        let result: Result<RustEmpty, RustBridgeError> = url.path.withCString { pointer in
            decodeEnvelope(voanisa_decoder_open_error_json(pointer))
        }
        if case .failure(let error) = result {
            return error.message
        }
        return nil
    }

    /// SHA-256 of the file contents, computed by the portable core so imports
    /// deduplicate identically on every platform.
    static func hashFile(url: URL) -> String? {
        let result: Result<RustHashPayload, RustBridgeError> = url.path.withCString { pointer in
            decodeEnvelope(voanisa_hash_file_json(pointer))
        }
        return try? result.get().hash
    }

    /// Writes the container's attached picture to `out`; false when the file
    /// carries no artwork. Ogg/Opus/WavPack/APE have no AVFoundation metadata,
    /// so their covers can only come from here.
    static func writeArtwork(url: URL, to out: URL) -> Bool {
        let result: Result<RustArtworkPayload, RustBridgeError> = out.path.withCString { outPointer in
            url.path.withCString { pathPointer in
                decodeEnvelope(voanisa_artwork_to_file_json(pathPointer, outPointer))
            }
        }
        return (try? result.get().written) ?? false
    }

    /// Renders a centred square JPEG cover through the portable core. False for
    /// formats `image` cannot decode (HEIC and friends), where the caller should
    /// fall back to ImageIO.
    static func writeSquareCover(source: URL, to out: URL, side: Int, quality: Int = 90) -> Bool {
        let status: RustStatus? = out.path.withCString { outPointer in
            source.path.withCString { srcPointer in
                guard let raw = voanisa_cover_to_file_json(
                    srcPointer,
                    outPointer,
                    UInt32(side),
                    UInt32(quality)
                ) else { return nil }
                defer { voanisa_string_free(raw) }
                return try? JSONDecoder().decode(
                    RustStatus.self,
                    from: Data(String(cString: raw).utf8)
                )
            }
        }
        return status?.ok ?? false
    }

    /// Mirrors the metadata editor into the audio file itself, so other players
    /// see the same title/artist/album. Missing fields remove those tags.
    static func writeTags(url: URL, tags: RustTagWrite) -> Bool {
        guard let data = try? JSONEncoder().encode(tags),
              let payload = String(data: data, encoding: .utf8) else {
            return false
        }

        let status: RustStatus? = url.path.withCString { pathPointer in
            payload.withCString { payloadPointer in
                guard let raw = voanisa_write_tags_json(pathPointer, payloadPointer)
                else { return nil }
                defer { voanisa_string_free(raw) }
                return try? JSONDecoder().decode(
                    RustStatus.self,
                    from: Data(String(cString: raw).utf8)
                )
            }
        }
        return status?.ok ?? false
    }
}

/// Tag values the editor sends back into the file.
struct RustTagWrite: Encodable {
    var title: String?
    var artist: String?
    var album: String?
    var albumArtist: String?
    var trackNumber: Int?
    var discNumber: Int?

    enum CodingKeys: String, CodingKey {
        case title, artist, album
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
    }

    init(track: Track) {
        title = track.title
        artist = track.artist
        album = track.album
        albumArtist = track.albumArtist
        trackNumber = track.trackNumber
        discNumber = track.discNumber
    }
}

/// Minimal envelope reader for calls that only report success.
struct RustStatus: Decodable {
    let ok: Bool
    let error: String?
}

struct RustHashPayload: Decodable {
    let hash: String
}

struct RustArtworkPayload: Decodable {
    let written: Bool
    let mime: String?
}

struct RustDecoderInfo: Decodable {
    let container: String
    let codec: String
    let sampleRate: Double
    let channels: Int
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case container, codec, channels
        case sampleRate = "sample_rate"
        case durationSeconds = "duration_seconds"
    }
}

struct RustTags: Decodable {
    let title: String?
    let artist: String?
    let album: String?
    let albumArtist: String?
    let trackNumber: Int?
    let discNumber: Int?
    let durationSeconds: Double

    enum CodingKeys: String, CodingKey {
        case title, artist, album
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case durationSeconds = "duration_seconds"
    }
}

/// Streaming decoder for containers AVFoundation cannot play.
///
/// The Rust core decodes and resamples nothing: it hands back interleaved
/// `Float` PCM at the file's own rate, and `AVAudioEngine` converts as needed.
/// Access must be serialized by the caller.
final class RustAudioDecoder {
    let info: RustDecoderInfo

    private var handle: OpaquePointer?

    init?(url: URL) {
        guard let handle = url.path.withCString({ voanisa_decoder_open($0) }) else {
            return nil
        }
        guard let raw = url.path.withCString({ path -> UnsafeMutablePointer<CChar>? in
            voanisa_decoder_info_json(handle)
        }) else {
            voanisa_decoder_close(handle)
            return nil
        }
        defer { voanisa_string_free(raw) }

        let json = String(cString: raw)
        guard let envelope = try? JSONDecoder().decode(RustEnvelope<RustDecoderInfo>.self, from: Data(json.utf8)),
              envelope.ok,
              let info = envelope.data else {
            voanisa_decoder_close(handle)
            return nil
        }

        self.handle = handle
        self.info = info
    }

    deinit {
        close()
    }

    func close() {
        guard let handle else { return }
        voanisa_decoder_close(handle)
        self.handle = nil
    }

    /// Interleaved samples. Empty at end of stream, `nil` on error.
    func read(frames: Int) -> [Float]? {
        guard let handle, frames > 0, info.channels > 0 else { return nil }

        var buffer = [Float](repeating: 0, count: frames * info.channels)
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            voanisa_decoder_read(handle, pointer.baseAddress, UInt32(frames))
        }
        guard count >= 0 else {
            Diagnostics.log("Rust 解码失败：\(lastError)")
            return nil
        }
        return Array(buffer[0..<Int(count) * info.channels])
    }

    func seek(to seconds: Double) -> Bool {
        guard let handle else { return false }
        guard voanisa_decoder_seek(handle, seconds) == 0 else {
            Diagnostics.log("Rust 定位失败：\(lastError)")
            return false
        }
        return true
    }

    var position: Double {
        guard let handle else { return 0 }
        return voanisa_decoder_position(handle)
    }

    private var lastError: String {
        guard let handle, let raw = voanisa_decoder_error_json(handle) else {
            return "unknown"
        }
        defer { voanisa_string_free(raw) }
        let json = String(cString: raw)
        guard let envelope = try? JSONDecoder().decode(RustEnvelope<RustEmpty>.self, from: Data(json.utf8)) else {
            return json
        }
        return envelope.error ?? "unknown"
    }
}

private func decodeEnvelope<T: Decodable>(
    _ pointer: UnsafeMutablePointer<CChar>?
) -> Result<T, RustBridgeError> {
    guard let pointer else {
        return .failure(RustBridgeError(message: "Rust returned no result", kind: "empty"))
    }
    defer { voanisa_string_free(pointer) }

    let text = String(cString: pointer)
    guard let data = text.data(using: .utf8) else {
        return .failure(RustBridgeError(message: "Rust returned invalid UTF-8", kind: "decode"))
    }

    do {
        let envelope = try JSONDecoder().decode(RustEnvelope<T>.self, from: data)
        if envelope.ok, let value = envelope.data {
            return .success(value)
        }
        return .failure(RustBridgeError(
            message: envelope.error ?? "Rust returned no data",
            kind: envelope.kind
        ))
    } catch {
        return .failure(RustBridgeError(
            message: "Invalid response from Rust: \(error.localizedDescription)",
            kind: "decode"
        ))
    }
}

struct RustTrack: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let albumArtist: String
    let trackNumber: Int?
    let discNumber: Int?
    let duration: Double
    let fileName: String
    let coverFileName: String?
    let format: String
    let contentHash: String
    let source: String
    let musicPersistentID: String?
    let dateAdded: Double
    let sortIndex: Int

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, format, source
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case fileName = "file_name"
        case coverFileName = "cover_file_name"
        case contentHash = "content_hash"
        case musicPersistentID = "music_persistent_id"
        case dateAdded = "date_added"
        case sortIndex = "sort_index"
    }
}

struct RustSnapshotCounts: Decodable {
    let tracks: Int
    let playlists: Int
}

struct RustNewTrack: Encodable {
    let id: String
    var title: String
    var artist = ""
    var album = ""
    var albumArtist = ""
    var trackNumber: Int?
    var discNumber: Int?
    var duration = 0.0
    let fileName: String
    var coverFileName: String?
    var format = ""
    let contentHash: String
    var source = "local"
    var musicPersistentID: String?
    let dateAdded: Double

    init(id: String, title: String, fileName: String, contentHash: String, dateAdded: Double) {
        self.id = id
        self.title = title
        self.fileName = fileName
        self.contentHash = contentHash
        self.dateAdded = dateAdded
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, format, source
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case fileName = "file_name"
        case coverFileName = "cover_file_name"
        case contentHash = "content_hash"
        case musicPersistentID = "music_persistent_id"
        case dateAdded = "date_added"
    }
}

struct RustTrackUpdate: Encodable {
    let id: String
    var title: String
    var artist = ""
    var album = ""
    var albumArtist = ""
    var trackNumber: Int?
    var discNumber: Int?
    var coverFileName: String?
    var musicPersistentID: String?

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    enum CodingKeys: String, CodingKey {
        case id, title, artist, album
        case albumArtist = "album_artist"
        case trackNumber = "track_number"
        case discNumber = "disc_number"
        case coverFileName = "cover_file_name"
        case musicPersistentID = "music_persistent_id"
    }
}

struct RustPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let sortIndex: Int
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name
        case sortIndex = "sort_index"
        case trackIDs = "track_ids"
    }
}

struct RustNewPlaylist: Encodable {
    let id: String
    let name: String
}

private struct RustRenamePlaylist: Encodable {
    let id: String
    let name: String
}

private struct RustPlaylistTracks: Encodable {
    let playlistID: String
    let trackIDs: [String]

    enum CodingKeys: String, CodingKey {
        case playlistID = "playlist_id"
        case trackIDs = "track_ids"
    }
}

struct RustBridgeError: LocalizedError, Equatable {
    let message: String
    let kind: String?

    var errorDescription: String? { message }
}

private struct RustEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let data: T?
    let error: String?
    let kind: String?
}

private struct RustEmpty: Decodable {}
private struct RustDeleteResult: Decodable { let deleted: Bool }
private struct RustSchemaVersion: Decodable { let version: Int }

/// Swift access to the Rust SQLite library.
///
/// Requests and responses travel as JSON, so Rust layout changes never break
/// the Swift side.
enum RustStore {
    /// Writes `library.json` from SQLite: the core owns the snapshot format.
    static func exportSnapshot(database: URL, to out: URL) -> RustSnapshotCounts? {
        let result: Result<RustSnapshotCounts, RustBridgeError> = database.path.withCString {
            dbPointer in
            out.path.withCString { outPointer in
                decodeEnvelope(voanisa_export_snapshot_json(dbPointer, outPointer))
            }
        }
        switch result {
        case .success(let counts):
            return counts
        case .failure(let error):
            Diagnostics.error(error.message, context: "library.snapshot.export")
            return nil
        }
    }

    /// Restores a snapshot into SQLite, skipping rows that already exist.
    static func importSnapshot(from json: URL, database: URL) -> RustSnapshotCounts? {
        let result: Result<RustSnapshotCounts, RustBridgeError> = json.path.withCString {
            jsonPointer in
            database.path.withCString { dbPointer in
                decodeEnvelope(voanisa_import_snapshot_json(jsonPointer, dbPointer))
            }
        }
        switch result {
        case .success(let counts):
            return counts
        case .failure(let error):
            Diagnostics.error(error.message, context: "library.snapshot.import")
            return nil
        }
    }

    static func schemaVersion(path: URL) -> Result<Int, RustBridgeError> {
        path.path.withCString { pathPointer in
            let result: Result<RustSchemaVersion, RustBridgeError> =
                decode(voanisa_schema_version_json(pathPointer))
            return result.map(\.version)
        }
    }

    static func tracks(path: URL, query: String? = nil) -> Result<[RustTrack], RustBridgeError> {
        path.path.withCString { pathPointer in
            if let query {
                return query.withCString { queryPointer in
                    decode(voanisa_tracks_json(pathPointer, queryPointer))
                }
            }
            return decode(voanisa_tracks_json(pathPointer, nil))
        }
    }

    static func insertTrack(path: URL, track: RustNewTrack) -> Result<RustTrack, RustBridgeError> {
        withEncoded(path: path, value: track) { pathPointer, payloadPointer in
            voanisa_insert_track_json(pathPointer, payloadPointer)
        }
    }

    static func insertTracks(path: URL, tracks: [RustNewTrack]) -> Result<[RustTrack], RustBridgeError> {
        withEncoded(path: path, value: tracks) { pathPointer, payloadPointer in
            voanisa_insert_tracks_json(pathPointer, payloadPointer)
        }
    }

    static func updateTrack(path: URL, update: RustTrackUpdate) -> Result<Void, RustBridgeError> {
        withEncodedVoid(path: path, value: update) { pathPointer, payloadPointer in
            voanisa_update_track_json(pathPointer, payloadPointer)
        }
    }

    static func deleteTrack(path: URL, id: String) -> Result<Bool, RustBridgeError> {
        path.path.withCString { pathPointer in
            id.withCString { idPointer in
                let result: Result<RustDeleteResult, RustBridgeError> =
                    decode(voanisa_delete_track_json(pathPointer, idPointer))
                return result.map(\.deleted)
            }
        }
    }

    static func reorderTracks(path: URL, ids: [String]) -> Result<Void, RustBridgeError> {
        withEncodedVoid(path: path, value: ids) { pathPointer, payloadPointer in
            voanisa_reorder_tracks_json(pathPointer, payloadPointer)
        }
    }

    static func syncTracks(path: URL, tracks: [RustNewTrack]) -> Result<Void, RustBridgeError> {
        withEncodedVoid(path: path, value: tracks) { pathPointer, payloadPointer in
            voanisa_sync_tracks_json(pathPointer, payloadPointer)
        }
    }

    static func playlists(path: URL) -> Result<[RustPlaylist], RustBridgeError> {
        path.path.withCString { pathPointer in
            let result: Result<[RustPlaylist], RustBridgeError> =
                decode(voanisa_playlists_json(pathPointer))
            return result
        }
    }

    static func createPlaylist(
        path: URL,
        id: String,
        name: String
    ) -> Result<RustPlaylist, RustBridgeError> {
        withEncoded(path: path, value: RustNewPlaylist(id: id, name: name)) {
            pathPointer, payloadPointer in
            voanisa_create_playlist_json(pathPointer, payloadPointer)
        }
    }

    static func renamePlaylist(
        path: URL,
        id: String,
        name: String
    ) -> Result<Void, RustBridgeError> {
        withEncodedVoid(path: path, value: RustRenamePlaylist(id: id, name: name)) {
            pathPointer, payloadPointer in
            voanisa_rename_playlist_json(pathPointer, payloadPointer)
        }
    }

    static func deletePlaylist(path: URL, id: String) -> Result<Bool, RustBridgeError> {
        path.path.withCString { pathPointer in
            id.withCString { idPointer in
                let result: Result<RustDeleteResult, RustBridgeError> =
                    decode(voanisa_delete_playlist_json(pathPointer, idPointer))
                return result.map(\.deleted)
            }
        }
    }

    static func setPlaylistTracks(
        path: URL,
        id: String,
        trackIDs: [String]
    ) -> Result<Void, RustBridgeError> {
        withEncodedVoid(
            path: path,
            value: RustPlaylistTracks(playlistID: id, trackIDs: trackIDs)
        ) { pathPointer, payloadPointer in
            voanisa_set_playlist_tracks_json(pathPointer, payloadPointer)
        }
    }

    private static func encodePayload<T: Encodable>(
        _ value: T
    ) -> Result<String, RustBridgeError> {
        do {
            let data = try JSONEncoder().encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                return .failure(RustBridgeError(message: "Could not encode request", kind: "encode"))
            }
            return .success(json)
        } catch {
            return .failure(RustBridgeError(message: error.localizedDescription, kind: "encode"))
        }
    }

    private static func withEncoded<T: Encodable, R: Decodable>(
        path: URL,
        value: T,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) -> Result<R, RustBridgeError> {
        switch encodePayload(value) {
        case .failure(let error):
            return .failure(error)
        case .success(let json):
            return path.path.withCString { pathPointer in
                json.withCString { payloadPointer in
                    decode(body(pathPointer, payloadPointer))
                }
            }
        }
    }

    private static func withEncodedVoid<T: Encodable>(
        path: URL,
        value: T,
        _ body: (UnsafePointer<CChar>, UnsafePointer<CChar>) -> UnsafeMutablePointer<CChar>?
    ) -> Result<Void, RustBridgeError> {
        switch encodePayload(value) {
        case .failure(let error):
            return .failure(error)
        case .success(let json):
            return path.path.withCString { pathPointer in
                json.withCString { payloadPointer in
                    decodeVoid(body(pathPointer, payloadPointer))
                }
            }
        }
    }

    private static func decode<T: Decodable>(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> Result<T, RustBridgeError> {
        guard let pointer else {
            return .failure(RustBridgeError(message: "Rust returned no result", kind: "empty"))
        }
        defer { voanisa_string_free(pointer) }

        let text = String(cString: pointer)
        guard let data = text.data(using: .utf8) else {
            return .failure(RustBridgeError(message: "Rust returned invalid UTF-8", kind: "decode"))
        }

        do {
            let envelope = try JSONDecoder().decode(RustEnvelope<T>.self, from: data)
            if envelope.ok, let value = envelope.data {
                return .success(value)
            }
            return .failure(RustBridgeError(
                message: envelope.error ?? "Rust returned no data",
                kind: envelope.kind
            ))
        } catch {
            return .failure(RustBridgeError(
                message: "Invalid response from Rust: \(error.localizedDescription)",
                kind: "decode"
            ))
        }
    }

    private static func decodeVoid(
        _ pointer: UnsafeMutablePointer<CChar>?
    ) -> Result<Void, RustBridgeError> {
        guard let pointer else {
            return .failure(RustBridgeError(message: "Rust returned no result", kind: "empty"))
        }
        defer { voanisa_string_free(pointer) }

        let text = String(cString: pointer)
        guard let data = text.data(using: .utf8) else {
            return .failure(RustBridgeError(message: "Rust returned invalid UTF-8", kind: "decode"))
        }

        do {
            let envelope = try JSONDecoder().decode(RustEnvelope<RustEmpty>.self, from: data)
            if envelope.ok {
                return .success(())
            }
            return .failure(RustBridgeError(
                message: envelope.error ?? "Rust returned an error",
                kind: envelope.kind
            ))
        } catch {
            return .failure(RustBridgeError(
                message: "Invalid response from Rust: \(error.localizedDescription)",
                kind: "decode"
            ))
        }
    }
}
