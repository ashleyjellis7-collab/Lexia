import Foundation
import LexiaCore

/// Settings shared between the Lexia app and the keyboard through the App Group.
struct LexiaSettings: Codable, Equatable {

    enum KeyFont: String, Codable, CaseIterable, Identifiable {
        case openDyslexic, rounded, system
        var id: String { rawValue }
        var title: String {
            switch self {
            case .openDyslexic: return "OpenDyslexic"
            case .rounded: return "Rounded"
            case .system: return "System"
            }
        }
    }

    /// Background tints. Coloured, low-glare backgrounds help many dyslexic readers.
    enum Tint: String, Codable, CaseIterable, Identifiable {
        case cream, blue, green, peach, lilac, grey, dark
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var font: KeyFont = .openDyslexic
    /// Show lowercase letters on keys (they match what you see in text).
    var lowercaseKeys = true
    var tint: Tint = .cream
    /// Give b, d, p and q their own colours so they're easy to tell apart.
    var letterColourCues = true
    /// 0.85…1.3, scales key and suggestion text.
    var textScale: Double = 1.0
    var autocorrectMode: AutocorrectMode = .whenConfident
    /// Use TypeSafe Jev to choose corrections from context (needs Full Access).
    var useJev = true
    /// Point out mixed-up words (their/there) after you type them.
    var reviewPreviousWords = true
    /// Long-press a suggestion to hear it read aloud.
    var speakSuggestions = true
    var jevBaseURL = "https://api.typesafe.ai"
    var jevModel = "jev-latest"

    init() {}

    // Decode field by field so new settings never wipe old ones.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LexiaSettings.init()
        font = (try? c.decode(KeyFont.self, forKey: .font)) ?? d.font
        lowercaseKeys = (try? c.decode(Bool.self, forKey: .lowercaseKeys)) ?? d.lowercaseKeys
        tint = (try? c.decode(Tint.self, forKey: .tint)) ?? d.tint
        letterColourCues = (try? c.decode(Bool.self, forKey: .letterColourCues)) ?? d.letterColourCues
        textScale = (try? c.decode(Double.self, forKey: .textScale)) ?? d.textScale
        autocorrectMode = (try? c.decode(AutocorrectMode.self, forKey: .autocorrectMode)) ?? d.autocorrectMode
        useJev = (try? c.decode(Bool.self, forKey: .useJev)) ?? d.useJev
        reviewPreviousWords = (try? c.decode(Bool.self, forKey: .reviewPreviousWords)) ?? d.reviewPreviousWords
        speakSuggestions = (try? c.decode(Bool.self, forKey: .speakSuggestions)) ?? d.speakSuggestions
        jevBaseURL = (try? c.decode(String.self, forKey: .jevBaseURL)) ?? d.jevBaseURL
        jevModel = (try? c.decode(String.self, forKey: .jevModel)) ?? d.jevModel
    }
}

/// Reads and writes settings and the personal dictionary in the shared App Group.
final class SettingsStore {
    static let shared = SettingsStore()

    /// From Info.plist (`LexiaAppGroup`), set in project.yml.
    static let appGroup = Bundle.main.object(forInfoDictionaryKey: "LexiaAppGroup") as? String

    private let defaults: UserDefaults
    private let settingsKey = "settings.v1"
    private let wordsKey = "personalWords.v1"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? Self.appGroup.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func load() -> LexiaSettings {
        guard let data = defaults.data(forKey: settingsKey),
              let settings = try? JSONDecoder().decode(LexiaSettings.self, from: data) else { return LexiaSettings() }
        return settings
    }

    func save(_ settings: LexiaSettings) {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: settingsKey) }
    }

    var personalWords: [String] {
        get { defaults.stringArray(forKey: wordsKey) ?? [] }
        set { defaults.set(Array(Set(newValue)).sorted(), forKey: wordsKey) }
    }

    func addPersonalWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !personalWords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        personalWords.append(w)
    }

    func removePersonalWord(_ word: String) {
        personalWords.removeAll { $0 == word }
    }
}
