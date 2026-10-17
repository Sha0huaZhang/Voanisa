import Foundation

/// Small append-only log at ~/Library/Logs/Voanisa.log.
///
/// It is intentionally independent of the UI so the same diagnostics can be
/// used by the future portable core.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "org.macwave.voanisa.diagnostics")
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    static var fileURL: URL {
        let directory = FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("Voanisa.log")
    }

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let url = fileURL
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }

    static func markSession() {
        log("")
        log("===== Voanisa \(AppVersion.display) =====")
        log("library = \(LibraryLocation.rootURL.path)")
    }
}

enum AppVersion {
    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    static var display: String { "\(current) (\(build))" }
}
