import SwiftUI
import AVFoundation
import LexiaCore

// The Train tab: type practice sentences with Lexia or Apple's keyboard,
// see what went wrong, teach Lexia, and share a feedback report.

enum TrainKeyboard: String, Codable, CaseIterable, Identifiable {
    case lexia = "Lexia"
    case apple = "Apple"
    var id: String { rawValue }
}

enum TrainMode: String, CaseIterable, Identifiable {
    case copy = "Copy it"
    case listen = "Listen & type"
    var id: String { rawValue }
}

struct TrainingRound: Codable, Identifiable {
    struct Miss: Codable, Hashable {
        let expected: String
        /// What ended up in the text ("" if the word was left out).
        let typed: String
        /// The letters actually typed, from Lexia's training log, when known.
        let raw: String?
    }

    var id = UUID()
    let date: Date
    let keyboard: TrainKeyboard
    let sentence: String
    let typed: String
    let accuracy: Double
    let misses: [Miss]
    /// Words Lexia changed to the right word.
    let fixes: [Miss]
}

@MainActor
final class TrainModel: ObservableObject {
    @Published var focus: PracticeSentence.Focus?
    @Published var mode: TrainMode = .copy
    @Published var keyboard: TrainKeyboard = .lexia
    @Published private(set) var sentence: PracticeSentence
    @Published var typed = ""
    @Published private(set) var results: [TrainingScorer.WordResult]?
    @Published private(set) var lastRound: TrainingRound?
    @Published var revealed = false
    @Published private(set) var history: [TrainingRound] = []
    @Published private(set) var taught: Set<String> = []

    private var roundStart = Date()
    private var roundEvents: [TrainingEvent] = []
    private let speech = AVSpeechSynthesizer()
    private let historyKey = "train.history.v1"

    init() {
        sentence = PracticeSentence.all.randomElement()!
        if let data = UserDefaults.standard.data(forKey: historyKey),
           let saved = try? JSONDecoder().decode([TrainingRound].self, from: data) {
            history = saved
        }
    }

    // MARK: Round flow

    /// Tells the keyboard to log finished words while the tab is open.
    func startTraining() {
        SettingsStore.shared.trainingActiveUntil = Date().addingTimeInterval(30 * 60)
    }

    func stopTraining() {
        SettingsStore.shared.trainingActiveUntil = nil
    }

    func nextSentence() {
        let pool = PracticeSentence.all.filter { (focus == nil || $0.focus == focus) && $0.id != sentence.id }
        sentence = pool.randomElement() ?? sentence
        typed = ""
        results = nil
        lastRound = nil
        revealed = false
        taught = []
        roundStart = Date()
        startTraining()
        if mode == .listen { speak() }
    }

    func speak() {
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: sentence.text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        speech.speak(utterance)
    }

    func check() {
        let scored = TrainingScorer.compare(target: sentence.text, typed: typed)
        results = scored
        revealed = true
        roundEvents = SettingsStore.shared.trainingLog.filter { $0.date >= roundStart }
        // If Lexia logged words this round, it was the keyboard in use.
        if !roundEvents.isEmpty { keyboard = .lexia }

        var misses: [TrainingRound.Miss] = []
        var fixes: [TrainingRound.Miss] = []
        for result in scored {
            guard let expected = result.expected else { continue }
            switch result.status {
            case .wrong(let word):
                misses.append(.init(expected: expected, typed: word, raw: event(endingAs: word)?.typed))
            case .missing:
                misses.append(.init(expected: expected, typed: "", raw: nil))
            case .correct:
                if let fix = event(endingAs: expected), fix.action == .autocorrected,
                   fix.typed.lowercased() != expected.lowercased() {
                    fixes.append(.init(expected: expected, typed: expected, raw: fix.typed))
                }
            case .extra:
                break
            }
        }
        let round = TrainingRound(date: Date(), keyboard: keyboard, sentence: sentence.text, typed: typed,
                                  accuracy: TrainingScorer.accuracy(scored), misses: misses, fixes: fixes)
        lastRound = round
        history.append(round)
        if history.count > 300 { history.removeFirst(history.count - 300) }
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: historyKey) }
    }

    /// The keyboard's record of the word that ended up as `word` this round.
    private func event(endingAs word: String) -> TrainingEvent? {
        roundEvents.last { $0.result.compare(word, options: .caseInsensitive) == .orderedSame }
    }

    // MARK: Teaching

    /// Teaches Lexia that what was typed should become `miss.expected`. Recorded
    /// twice, so it is fixed automatically next time, even for real words.
    func teach(_ miss: TrainingRound.Miss) {
        let from = miss.raw ?? miss.typed
        guard !from.isEmpty, from.lowercased() != miss.expected.lowercased() else { return }
        let learning = LearningModel(data: SettingsStore.shared.learningData)
        learning.recordCorrection(from: from, to: miss.expected)
        learning.recordCorrection(from: from, to: miss.expected)
        SettingsStore.shared.learningData = learning.save()
        taught.insert(miss.expected)
    }

    func canTeach(_ miss: TrainingRound.Miss) -> Bool {
        let from = miss.raw ?? miss.typed
        return !from.isEmpty && from.lowercased() != miss.expected.lowercased()
    }

    // MARK: Scores and report

    func stats(for keyboard: TrainKeyboard) -> (rounds: Int, average: Double) {
        let rounds = history.filter { $0.keyboard == keyboard }
        guard !rounds.isEmpty else { return (0, 0) }
        return (rounds.count, rounds.map(\.accuracy).reduce(0, +) / Double(rounds.count))
    }

    var report: String {
        var lines = ["Lexia training report – \(Date().formatted(date: .abbreviated, time: .shortened))", ""]
        for keyboard in TrainKeyboard.allCases {
            let s = stats(for: keyboard)
            if s.rounds > 0 {
                lines.append("\(keyboard.rawValue) keyboard: \(s.rounds) rounds, \(Int(s.average * 100))% of words right")
            }
        }
        let recent = history.suffix(40)
        let misses = recent.flatMap { round in round.misses.map { (round.keyboard, $0) } }
        if !misses.isEmpty {
            lines += ["", "Words that went wrong:"]
            for (keyboard, miss) in misses {
                var line = "• [\(keyboard.rawValue)] wanted “\(miss.expected)”"
                if miss.typed.isEmpty {
                    line += " – left out"
                } else if let raw = miss.raw, raw != miss.typed {
                    line += " – typed “\(raw)”, Lexia made it “\(miss.typed)”"
                } else {
                    line += " – got “\(miss.typed)”"
                }
                lines.append(line)
            }
        }
        let fixes = recent.filter { $0.keyboard == .lexia }.flatMap(\.fixes)
        if !fixes.isEmpty {
            lines += ["", "Words Lexia fixed:"]
            lines += fixes.map { "• “\($0.raw ?? "")” → “\($0.expected)”" }
        }
        return lines.joined(separator: "\n")
    }

    func clearHistory() {
        history = []
        UserDefaults.standard.removeObject(forKey: historyKey)
        SettingsStore.shared.trainingLog = []
    }
}

struct TrainView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var model = TrainModel()
    @FocusState private var typing: Bool
    @State private var copied = false

    private var settings: LexiaSettings { app.settings }
    private var theme: Theme { Theme.make(settings.tint) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    options
                    sentenceCard
                    typingBox
                    if let round = model.lastRound, let results = model.results {
                        resultsView(round, results)
                    }
                    scoreboard
                    feedback
                }
                .padding()
            }
            .navigationTitle("Train")
            .scrollDismissesKeyboard(.interactively)
            .onAppear { model.startTraining() }
            .onDisappear { model.stopTraining() }
        }
    }

    // MARK: Sections

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Practise", selection: $model.focus) {
                Text("A mix").tag(PracticeSentence.Focus?.none)
                ForEach(PracticeSentence.Focus.allCases) { Text($0.rawValue).tag(Optional($0)) }
            }
            .pickerStyle(.menu)
            Picker("Mode", selection: $model.mode) {
                ForEach(TrainMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Keyboard", selection: $model.keyboard) {
                ForEach(TrainKeyboard.allCases) { Text("\($0.rawValue) keyboard").tag($0) }
            }
            .pickerStyle(.segmented)
            Text("Switch keyboards with the 🌐 key. Lexia is spotted automatically when it's in use.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var sentenceCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.sentence.focus.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.speak() } label: { Label("Listen", systemImage: "speaker.wave.2.fill") }
                    .buttonStyle(.bordered)
            }
            if model.mode == .copy || model.revealed {
                Text(model.sentence.text)
                    .font(settings.keyFont(size: 22))
                    .foregroundColor(theme.text)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Button("Show the sentence") { model.revealed = true }
                    .font(settings.keyFont(size: 18))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(theme.background))
    }

    private var typingBox: some View {
        VStack(spacing: 10) {
            TextEditor(text: $model.typed)
                .font(settings.keyFont(size: 20))
                .focused($typing)
                .frame(minHeight: 110)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.3)))
            HStack {
                Button {
                    typing = false
                    model.check()
                } label: {
                    Label("Check", systemImage: "checkmark.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button {
                    model.nextSentence()
                    typing = true
                } label: {
                    Label("Next", systemImage: "arrow.right.circle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func resultsView(_ round: TrainingRound, _ results: [TrainingScorer.WordResult]) -> some View {
        let right = results.filter(\.isCorrect).count
        let total = results.filter { $0.expected != nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            Text(right == total ? "🎉 All \(total) words right!" : "\(right) of \(total) words right")
                .font(settings.keyFont(size: 22, bold: true))
            coloured(results)
                .font(settings.keyFont(size: 18))
                .fixedSize(horizontal: false, vertical: true)

            if !round.fixes.isEmpty {
                Text("Lexia fixed: " + round.fixes.map { "\($0.raw ?? "") → \($0.expected)" }.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.green)
            }

            ForEach(round.misses, id: \.self) { miss in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("“\(miss.expected)”").font(settings.keyFont(size: 18, bold: true))
                        Text(describe(miss)).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.canTeach(miss) {
                        if model.taught.contains(miss.expected) {
                            Label("Taught", systemImage: "checkmark").font(.callout).foregroundStyle(.green)
                        } else {
                            Button("Teach Lexia") { model.teach(miss) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.07)))
            }
            if round.misses.contains(where: model.canTeach) {
                Text("“Teach Lexia” makes the keyboard fix that spelling automatically next time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func describe(_ miss: TrainingRound.Miss) -> String {
        if miss.typed.isEmpty { return "Left out" }
        if let raw = miss.raw, raw != miss.typed { return "You typed “\(raw)”, Lexia made it “\(miss.typed)”" }
        return "You got “\(miss.typed)”"
    }

    /// The sentence with right words in green and wrong or missing ones in red.
    private func coloured(_ results: [TrainingScorer.WordResult]) -> Text {
        results.reduce(Text("")) { text, result in
            let word: Text
            switch result.status {
            case .correct: word = Text(result.expected ?? "").foregroundColor(.green)
            case .wrong(let typed): word = Text(typed).foregroundColor(.red).strikethrough()
            case .missing: word = Text("[\(result.expected ?? "")]").foregroundColor(.orange)
            case .extra(let typed): word = Text(typed).foregroundColor(.red).strikethrough()
            }
            return text + word + Text(" ")
        }
    }

    private var scoreboard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scoreboard").font(.headline)
            HStack {
                ForEach(TrainKeyboard.allCases) { keyboard in
                    let s = model.stats(for: keyboard)
                    VStack(spacing: 4) {
                        Text(keyboard.rawValue).font(.subheadline.weight(.semibold))
                        Text(s.rounds == 0 ? "–" : "\(Int(s.average * 100))%")
                            .font(.system(size: 30, weight: .bold, design: .rounded))
                        Text("\(s.rounds) round\(s.rounds == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                }
            }
            Text("Percentage of words typed right after each keyboard's corrections.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var feedback: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Send feedback").font(.headline)
            Text("Share the report with the Lexia team (or paste it into your chat with Claude). Every miss becomes a test, so Lexia gets better with each update.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                ShareLink(item: model.report) { Label("Share report", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Button {
                    UIPasteboard.general.string = model.report
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
            }
            Button("Clear scores", role: .destructive) { model.clearHistory() }
                .font(.footnote)
        }
    }
}
