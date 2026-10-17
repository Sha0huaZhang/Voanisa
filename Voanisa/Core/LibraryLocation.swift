import Foundation

/// The self-contained Voanisa library:
///
///     ~/Music/Voanisa/
///       library.sqlite         primary store
///       library.json           portable snapshot and migration fallback
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
    static var databaseURL: URL { rootURL.appendingPathComponent("library.sqlite") }
    static var libraryFileURL: URL { rootURL.appendingPathComponent("library.json") }

    static func ensureDirectories() throws {
        try ensureDirectories(rootURL: rootURL)
    }

    static func ensureDirectories(rootURL: URL) throws {
        let media = rootURL.appendingPathComponent("Media", isDirectory: true)
        let covers = rootURL.appendingPathComponent("Covers", isDirectory: true)
        let originals = covers.appendingPathComponent("Originals", isDirectory: true)
        let rendered = covers.appendingPathComponent("Rendered", isDirectory: true)
        let staging = rootURL.appendingPathComponent(".staging", isDirectory: true)

        for url in [rootURL, media, originals, rendered, staging] {
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
        cleanStaging(rootURL: rootURL)
    }

    static func cleanStaging(rootURL: URL) {
        let staging = rootURL.appendingPathComponent(".staging", isDirectory: true)
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for child in children {
            try? FileManager.default.removeItem(at: child)
        }
    }
}
