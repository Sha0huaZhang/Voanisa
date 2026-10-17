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
