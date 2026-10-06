import SwiftUI
import LexiaCore

@main
struct LexiaApp: App {
    @StateObject private var model = AppModel()

    init() {
        FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                SetupView()
                    .tabItem { Label("Set up", systemImage: "keyboard") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
                TryItView()
                    .tabItem { Label("Try it", systemImage: "text.cursor") }
            }
            .environmentObject(model)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings: LexiaSettings {
        didSet { if settings != oldValue { SettingsStore.shared.save(settings) } }
    }
    @Published var apiKey: String
    @Published var personalWords: [String]
    @Published var jevTestResult: String?
    @Published var isTestingJev = false

    init() {
        settings = SettingsStore.shared.load()
        apiKey = KeychainStore.readAPIKey() ?? ""
        personalWords = SettingsStore.shared.personalWords
    }

    var hasAPIKey: Bool { !apiKey.trimmingCharacters(in: .whitespaces).isEmpty }

    func saveAPIKey() {
        KeychainStore.saveAPIKey(apiKey)
        jevTestResult = nil
    }

    func removeWord(_ word: String) {
        SettingsStore.shared.removePersonalWord(word)
        personalWords = SettingsStore.shared.personalWords
    }

    func reloadWords() {
        personalWords = SettingsStore.shared.personalWords
    }

    /// Sends one sample decision to Jev to check the key and connection.
    func testJev() async {
        guard let url = URL(string: settings.jevBaseURL) else {
            jevTestResult = "That server address doesn't look right."
            return
        }
        isTestingJev = true
        defer { isTestingJev = false }
        let client = JevClient(configuration: JevConfiguration(apiKey: apiKey, baseURL: url, model: settings.jevModel,
                                                              timeout: 10))
        let started = Date()
        do {
            let decision = try await JevReranker(client: client).decide(
                context: TypingContext(before: "I can't come to the party ", word: "becuz", after: " I'm sick."),
                options: ["becuz", "because", "bucks", "becks"]
            )
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            jevTestResult = "✅ Jev works! “becuz” → “\(decision.choice)” (\(Int(decision.confidence * 100))% sure, \(ms) ms)"
        } catch {
            jevTestResult = "⚠️ \(error.localizedDescription)"
        }
    }
}
