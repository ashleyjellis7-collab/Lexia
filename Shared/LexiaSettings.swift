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
    /// Vibrate on each key press (needs Full Access).
    var keyVibration = false
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
        keyVibration = (try? c.decode(Bool.self, forKey: .keyVibration)) ?? d.keyVibration
        jevBaseURL = (try? c.decode(String.self, forKey: .jevBaseURL)) ?? d.jevBaseURL
        jevModel = (try? c.decode(String.self, forKey: .jevModel)) ?? d.jevModel
    }
}

/// Reads and writes settings and the personal dictionary, shared between the
/// app and keyboard through the Keychain. A local copy is kept as a fallback
/// in case the Keychain can't be reached (e.g. the keyboard without Full Access).
final class SettingsStore {
    static let shared = SettingsStore()

    private let local = UserDefaults.standard
    private let settingsKey = "settings.v1"
    private let wordsKey = "personalWords.v1"

    private func read(_ key: String) -> Data? {
        KeychainStore.data(for: key) ?? local.data(forKey: key)
    }

    private func write(_ data: Data, _ key: String) {
        local.set(data, forKey: key)
        KeychainStore.set(data, for: key)
    }

    func load() -> LexiaSettings {
        guard let data = read(settingsKey),
              let settings = try? JSONDecoder().decode(LexiaSettings.self, from: data) else { return LexiaSettings() }
        return settings
    }

    func save(_ settings: LexiaSettings) {
        if let data = try? JSONEncoder().encode(settings) { write(data, settingsKey) }
    }

    var personalWords: [String] {
        get {
            guard let data = read(wordsKey) else { return [] }
            return (try? JSONDecoder().decode([String].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(Array(Set(newValue)).sorted()) { write(data, wordsKey) }
        }
    }

    /// Whether the one-time clean-up of mistakenly learned words has run.
    var didCleanPersonalWords: Bool {
        get { read("cleanup.v1") != nil }
        set { if newValue { write(Data([1]), "cleanup.v1") } }
    }

    /// What the keyboard has learned from your typing (see `LearningModel`).
    var learningData: Data? {
        get { read(learningKey) }
        set { if let newValue { write(newValue, learningKey) } }
    }
    private let learningKey = "learning.v1"

    func addPersonalWord(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !personalWords.contains(where: { $0.caseInsensitiveCompare(w) == .orderedSame }) else { return }
        personalWords.append(w)
    }

    func removePersonalWord(_ word: String) {
        personalWords.removeAll { $0 == word }
    }
}
