import Foundation

/// The self-contained Voanisa library:
///
///     ~/Music/Voanisa/
///       library.json
///       Media/                 audio files, UUID names
///       Covers/Originals/      user-supplied cover originals
///       Covers/Rendered/       square covers used by the UI
///       .staging/              temporary import area
enum LibraryLocation {
    static var rootURL: URL {
        // Environment override keeps tests and the portable core independent of
        // the user's real library.
        if let override = ProcessInfo.processInfo.environment["VOANISA_LIBRARY"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Voanisa", isDirectory: true)
    }

    static var mediaURL: URL { rootURL.appendingPathComponent("Media", isDirectory: true) }
    static var coversURL: URL { rootURL.appendingPathComponent("Covers", isDirectory: true) }
    static var originalCoversURL: URL { coversURL.appendingPathComponent("Originals", isDirectory: true) }
    static var renderedCoversURL: URL { coversURL.appendingPathComponent("Rendered", isDirectory: true) }
    static var stagingURL: URL { rootURL.appendingPathComponent(".staging", isDirectory: true) }
    static var libraryFileURL: URL { rootURL.appendingPathComponent("library.json") }

    static func ensureDirectories() throws {
        for url in [rootURL, mediaURL, originalCoversURL, renderedCoversURL, stagingURL] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    static func mediaURL(for fileName: String) -> URL {
        mediaURL.appendingPathComponent(fileName)
    }

    static func coverURL(for fileName: String) -> URL {
        renderedCoversURL.appendingPathComponent(fileName)
    }

    /// Removes stale staging entries left behind by a crash or a cancelled import.
    static func cleanStaging() {
        guard let children = try? FileManager.default.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil) else {
            return
        }
        for child in children {
            try? FileManager.default.removeItem(at: child)
        }
    }
}
