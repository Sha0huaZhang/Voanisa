import SwiftUI

/// The interface language.
///
/// This uses the standard macOS mechanism: the choice is written into the
/// app's `AppleLanguages`, and the next launch picks the matching
/// `Localizable.strings`. A restart is therefore required.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system = ""
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system: return "settings.language.system"
        case .english: return "settings.language.english"
        case .simplifiedChinese: return "settings.language.chinese"
        }
    }

    /// Writes or clears `AppleLanguages` for this app.
    func apply() {
        switch self {
        case .system:
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        case .english, .simplifiedChinese:
            UserDefaults.standard.set([rawValue], forKey: "AppleLanguages")
        }
    }

    /// The language currently in effect, for restoring the picker state.
    static var current: AppLanguage {
        guard let code = Bundle.main.preferredLocalizations.first else { return .system }
        return AppLanguage(rawValue: code) ?? .system
    }
}
