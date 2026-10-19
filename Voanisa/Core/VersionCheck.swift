import Foundation

/// Version comparison, kept free of networking so the rules can be tested.
enum VersionCheck {
    enum Outcome: Equatable {
        /// Already on the newest release.
        case upToDate
        /// A newer release exists.
        case updateAvailable(latest: String)
        /// The lookup failed, or the answer made no sense.
        case failed
    }

    /// Splits "v1.2.3", "1.2.3" or "1.2.3-beta.1" into comparable numbers. A
    /// leading `v` and any pre-release suffix are ignored.
    static func components(_ raw: String) -> [Int] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[text.startIndex ..< dash]) }
        guard !text.isEmpty else { return [] }
        return text.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }

    /// Missing segments count as zero, so `1.2` and `1.2.0` are the same version.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let candidateParts = components(candidate)
        let currentParts = components(current)
        guard !candidateParts.isEmpty, !currentParts.isEmpty else { return false }

        for index in 0 ..< max(candidateParts.count, currentParts.count) {
            let lhs = index < candidateParts.count ? candidateParts[index] : 0
            let rhs = index < currentParts.count ? currentParts[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    static func outcome(current: String, latestTag: String?) -> Outcome {
        guard let tag = latestTag, !components(tag).isEmpty else { return .failed }
        return isNewer(tag, than: current) ? .updateAvailable(latest: display(tag)) : .upToDate
    }

    /// Version text without the tag's `v` prefix.
    static func display(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.first == "v" || text.first == "V" { text.removeFirst() }
        return text
    }

    /// The finished "Version %@ is available" sentence.
    ///
    /// Looked up by key and filled in by hand: handing SwiftUI
    /// `Text("settings.version.available \(latest)")` turns the lookup key into
    /// `settings.version.available %@`, which does not match the `.strings` key
    /// and shows the key name instead of the sentence.
    static func availableMessage(
        latest: String,
        bundle: Bundle = .main,
        table: String? = nil
    ) -> String {
        let format = bundle.localizedString(
            forKey: "settings.version.available",
            value: nil,
            table: table
        )
        return String(format: format, latest)
    }
}

/// Asks GitHub for the newest release tag of this app.
enum UpdateChecker {
    static let downloadPage = URL(string: "https://voanisa.macwave.org/Downloads/")!

    private static let latestReleaseURL =
        URL(string: "https://api.github.com/repos/Sha0huaZhang/Voanisa/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
    }

    static func latestTag() async throws -> String {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data).tag_name
    }
}
