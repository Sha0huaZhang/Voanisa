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
/// The Swift app does not read from this store yet; M1-3 only exposes and tests
/// the bridge.
enum RustStore {
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
