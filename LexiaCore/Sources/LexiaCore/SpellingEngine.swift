import Foundation

/// One possible word the writer meant.
public struct Candidate: Sendable, Hashable {
    /// Display form from the lexicon (casing not yet matched to the typed word).
    public let word: String
    /// Dyslexia-weighted edit cost from what was typed.
    public let editCost: Double
    /// Whether it sounds like what was typed.
    public let soundsAlike: Bool
    /// Lexicon weight, 0...1.
    public let weight: Double
    /// Combined local score; higher is better.
    public let score: Double
}

/// Fast, on-device analysis of the word at the cursor.
public struct SpellingResult: Sendable, Equatable {
    public let typed: String
    /// The typed word is a real word (lexicon or personal dictionary).
    public let isKnownWord: Bool
    /// Corrections, best first. Never contains the typed word itself.
    public let candidates: [Candidate]
    /// Frequent words starting with the typed letters, best first.
    public let completions: [String]
    /// What a confident on-device autocorrect would change the word to.
    public let autocorrect: String?
    /// Softmax over the typed word (if known) and candidates, keyed by lowercase word.
    public let probabilities: [String: Double]

    public static func == (a: SpellingResult, b: SpellingResult) -> Bool {
        a.typed == b.typed && a.candidates == b.candidates && a.completions == b.completions
            && a.autocorrect == b.autocorrect
    }
}

/// Dyslexia-aware spelling correction that runs entirely on the device.
///
/// Every lexicon word within reach is scored by `EditCost` (with a bonus for
/// sounding the same) and by how common it is. On an iPhone this scans the
/// 38k-word lexicon in a few milliseconds.
public final class SpellingEngine: @unchecked Sendable {

    public let lexicon: Lexicon
    private let lock = NSLock()
    private var personalWords: Set<String>

    /// Words typed without their apostrophe that should always be fixed.
    static let apostropheFixes: [String: String] = [
        "dont": "don't", "cant": "can't", "wont": "won't", "isnt": "isn't", "arent": "aren't",
        "wasnt": "wasn't", "werent": "weren't", "didnt": "didn't", "doesnt": "doesn't",
        "couldnt": "couldn't", "wouldnt": "wouldn't", "shouldnt": "shouldn't", "havent": "haven't",
        "hasnt": "hasn't", "hadnt": "hadn't", "im": "I'm", "ive": "I've", "youre": "you're",
        "theyre": "they're", "thats": "that's", "whats": "what's", "youve": "you've",
        "theyve": "they've", "wouldve": "would've", "couldve": "could've", "shouldve": "should've",
    ]

    /// What this writer's typing has taught Lexia (usage, picked fixes, undos).
    public let learning: LearningModel

    public init(lexicon: Lexicon, personalWords: [String] = [], learning: LearningModel = LearningModel()) {
        self.lexicon = lexicon
        self.personalWords = Set(personalWords.map { $0.lowercased() })
        self.learning = learning
    }

    /// Words the writer has told us are right (kept, learned, or from contacts).
    public func learn(_ words: some Sequence<String>) {
        lock.lock(); defer { lock.unlock() }
        for word in words { personalWords.insert(TextScanner.normalized(word).lowercased()) }
    }

    public func forget(_ word: String) {
        lock.lock(); defer { lock.unlock() }
        personalWords.remove(word.lowercased())
    }

    public func isKnown(_ word: String) -> Bool {
        let w = TextScanner.normalized(word).lowercased()
        lock.lock(); defer { lock.unlock() }
        return personalWords.contains(w) || lexicon.contains(w)
    }

    private func isPersonal(_ word: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return personalWords.contains(word)
    }

    public func analyze(_ rawTyped: String, limit: Int = 5) -> SpellingResult {
        let typed = TextScanner.normalized(rawTyped)
        let lower = typed.lowercased()
        let bytes = Array(lower.utf8)
        let known = isKnown(lower)

        // Only plain English letters are analysed; anything else is left alone.
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 128 }) else {
            return SpellingResult(typed: typed, isKnownWord: known, candidates: [], completions: [],
                                  autocorrect: nil, probabilities: [:])
        }

        let typedKeys = Phonetic.keys(for: lower)
        let typedMask = Lexicon.letterMask(bytes)
        let typedLetterCount = typedMask.nonzeroBitCount
        // A candidate must share most of the typed letters (or sound alike).
        let minSharedLetters = typedLetterCount - (1 + typedLetterCount / 4)
        let maxLengthGap = max(2, bytes.count / 3)
        let maxCost = 3.0
        var scratch: [Double] = []
        var candidates: [Candidate] = []
        var completions: [String] = []

        for entry in lexicon.entries {
            if entry.bytes == bytes { continue }

            if completions.count < 3, bytes.count >= 2, entry.bytes.count > bytes.count,
               entry.bytes.starts(with: bytes) {
                completions.append(entry.word)
            }

            let soundsAlike = entry.phoneticKeys.contains(where: { typedKeys.contains($0) })
            if !soundsAlike {
                if abs(entry.bytes.count - bytes.count) > maxLengthGap { continue }
                if (entry.letterMask & typedMask).nonzeroBitCount < minSharedLetters { continue }
            }

            var cost = EditCost.distance(bytes, entry.bytes, limit: maxCost, scratch: &scratch)
            if soundsAlike { cost = min(cost, 0.5 + 0.3 * cost) }
            guard cost <= maxCost else { continue }

            var score = Self.score(cost: cost, weight: entry.weight) + learning.usageBoost(entry.key)
            if entry.bytes.count <= 2 && bytes.count >= 4 { score -= 1 }
            candidates.append(Candidate(word: entry.word, editCost: cost, soundsAlike: soundsAlike,
                                        weight: entry.weight, score: score))
        }

        candidates.sort { $0.score > $1.score }

        // A fix this writer has picked before goes to the top.
        let learnedFix = learning.learnedFix(for: lower)
        if let fix = learnedFix {
            let fixLower = fix.word.lowercased()
            let cost = candidates.first { $0.word.lowercased() == fixLower }?.editCost
                ?? EditCost.distance(bytes, Array(fixLower.utf8), scratch: &scratch)
            candidates.removeAll { $0.word.lowercased() == fixLower }
            let top = (candidates.first?.score ?? 0) + 1 + Double(min(fix.strength, 5)) * 0.2
            candidates.insert(Candidate(word: fix.word, editCost: cost, soundsAlike: false,
                                        weight: lexicon.entry(for: fixLower)?.weight ?? 0.5, score: top), at: 0)
        }
        candidates = Array(candidates.prefix(limit))

        let probabilities = Self.softmax(
            typed: known ? (lower, Self.score(cost: 0, weight: lexicon.entry(for: lower)?.weight ?? 0.5)
                                    + learning.usageBoost(lower)) : nil,
            candidates: candidates
        )

        return SpellingResult(
            typed: typed,
            isKnownWord: known,
            candidates: candidates,
            completions: completions,
            autocorrect: autocorrect(typed: typed, lower: lower, known: known, candidates: candidates,
                                     learnedFix: learnedFix),
            probabilities: probabilities
        )
    }

    static func score(cost: Double, weight: Double) -> Double {
        -1.6 * cost + 1.8 * weight
    }

    private func autocorrect(typed: String, lower: String, known: Bool, candidates: [Candidate],
                             learnedFix: (word: String, strength: Int)?) -> String? {
        // A fix the writer keeps choosing: once for a misspelling, twice for a real word ("luke" → like).
        if let fix = learnedFix, fix.strength >= (known ? 2 : 1) {
            return Casing.apply(from: typed, to: fix.word)
        }
        if isPersonal(lower) { return nil }
        if let fix = Self.apostropheFixes[lower], !learning.isRejected(lower, fix) {
            return Casing.apply(from: typed, to: fix)
        }
        if known {
            // "i" → "I", "monday" → "Monday": only when the writer typed all lowercase.
            if let display = lexicon.entry(for: lower)?.word, display != lower, typed == lower {
                return display
            }
            return nil
        }
        guard lower.count >= 2, let best = candidates.first, best.editCost <= 1.5,
              !learning.isRejected(lower, best.word) else { return nil }
        if candidates.count > 1, best.score - candidates[1].score < 0.35 { return nil }
        return Casing.apply(from: typed, to: best.word)
    }

    private static func softmax(typed: (String, Double)?, candidates: [Candidate]) -> [String: Double] {
        let temperature = 0.6
        var scores: [(String, Double)] = candidates.map { ($0.word.lowercased(), $0.score) }
        if let typed { scores.append(typed) }
        guard let maxScore = scores.map(\.1).max() else { return [:] }
        let exps = scores.map { ($0.0, exp(($0.1 - maxScore) / temperature)) }
        let total = exps.reduce(0) { $0 + $1.1 }
        var result: [String: Double] = [:]
        for (word, e) in exps { result[word, default: 0] += e / total }
        return result
    }
}
