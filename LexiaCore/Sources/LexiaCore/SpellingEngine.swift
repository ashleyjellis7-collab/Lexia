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
        // Common shortenings.
        "coz": "because", "cuz": "because", "bcuz": "because",
    ]

    /// What this writer's typing has taught Lexia (usage, picked fixes, undos).
    public let learning: LearningModel

    /// Which words tend to follow which; set once at start-up.
    public var context: ContextModel?

    /// Strength of the word-before context in scoring.
    static let contextWeight = 0.6
    /// How much better (in score) a near-miss must fit the sentence before a
    /// real word is swapped for it ("he us" → is).
    static let realWordSwapMargin = 0.5

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

    /// Score bonus for how well `word` fits after `previous` (0 without context).
    func contextBonus(_ word: String, after previous: String?) -> Double {
        guard let previous, let lift = context?.contextLift(of: word, after: previous) else { return 0 }
        return Self.contextWeight * max(-2, min(2.5, lift))
    }

    /// The words most likely to come next, written properly ("i" → "I").
    public func predictions(after previous: String, limit: Int = 3) -> [String] {
        guard let context else { return [] }
        return context.predictions(after: previous, limit: limit + 3)
            .filter { $0 != ContextModel.sentenceStart }
            .map { lexicon.entry(for: $0)?.word ?? $0 }
            .prefix(limit).map { $0 }
    }

    /// - Parameter previous: the word before (lowercase), or `<s>` at the start of a sentence.
    /// - Parameter isDictionaryWord: the system dictionary knows the word ("woofs", "typos"),
    ///   so it is never treated as a misspelling.
    /// - Parameter touches: where each letter was touched, for telling slips onto a neighbouring key apart.
    public func analyze(_ rawTyped: String, previous: String? = nil, isDictionaryWord: Bool = false,
                        touches: [KeyTouch] = [], limit: Int = 5, allowSplit: Bool = true) -> SpellingResult {
        let typed = TextScanner.normalized(rawTyped)
        let lower = typed.lowercased()
        let bytes = Array(lower.utf8)
        let known = isKnown(lower) || isDictionaryWord

        // Only plain English letters are analysed; anything else is left alone.
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 < 128 }) else {
            return SpellingResult(typed: typed, isKnownWord: known, candidates: [], completions: [],
                                  autocorrect: nil, probabilities: [:])
        }

        let rowCosts = EditCost.touchRows(for: bytes, touches: touches)
        let typedKeys = Phonetic.keys(for: lower)
        let typedMask = Lexicon.letterMask(bytes)
        let typedLetterCount = typedMask.nonzeroBitCount
        // A candidate must share most of the typed letters (or sound alike). Short words
        // only need one in common: a couple of slips can change most of them ("tbr" → the).
        let minSharedLetters = bytes.count <= 4 ? 1 : typedLetterCount - (1 + typedLetterCount / 4)
        let maxLengthGap = max(2, bytes.count / 3)
        let maxCost = 3.0
        var scratch: [Double] = []
        var candidates: [Candidate] = []
        var prefixMatches: [Lexicon.Entry] = []

        for entry in lexicon.entries {
            if entry.bytes == bytes { continue }

            if prefixMatches.count < 40, bytes.count >= 2, entry.bytes.count > bytes.count,
               entry.bytes.starts(with: bytes) {
                prefixMatches.append(entry)
            }

            let soundsAlike = entry.phoneticKeys.contains(where: { typedKeys.contains($0) })
            if !soundsAlike {
                if abs(entry.bytes.count - bytes.count) > maxLengthGap { continue }
                if (entry.letterMask & typedMask).nonzeroBitCount < minSharedLetters { continue }
            }

            // Sound-alikes may be spelled very differently ("nolij" → knowledge), so look further.
            var cost = EditCost.distance(bytes, entry.bytes, limit: soundsAlike ? 8 : maxCost, scratch: &scratch,
                                         rowCosts: rowCosts)
            if soundsAlike { cost = min(cost, 0.5 + 0.3 * cost) }
            guard cost <= maxCost else { continue }

            var score = Self.score(cost: cost, weight: entry.weight) + learning.usageBoost(entry.key)
                + contextBonus(entry.key, after: previous)
            if entry.bytes.count <= 2 && bytes.count >= 4 { score -= 1 }
            // A name ("Riggs") is an unlikely fix for a word typed in lowercase ("roghgs" → rights).
            if typed == lower, entry.word.first?.isUppercase == true, entry.key != "i", !entry.key.hasPrefix("i'") {
                score -= 0.4
            }
            candidates.append(Candidate(word: entry.word, editCost: cost, soundsAlike: soundsAlike,
                                        weight: entry.weight, score: score))
        }

        candidates.sort { $0.score > $1.score }

        // A fix this writer has picked before goes to the top.
        // Learned fixes are stored as first chosen, so a fix picked at the start of a sentence
        // ("th" → The) would keep its capital everywhere. Use the dictionary's own form.
        let learnedFix = learning.learnedFix(for: lower).map { fix in
            (word: lexicon.entry(for: fix.word.lowercased())?.word ?? fix.word, strength: fix.strength)
        }
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

        // Completions: common words starting with what was typed, best fit for the sentence first.
        let completions = prefixMatches
            .map { ($0.word, 1.8 * $0.weight + learning.usageBoost($0.key) + contextBonus($0.key, after: previous)) }
            .sorted { $0.1 > $1.1 }
            .prefix(3).map(\.0)

        let typedScore = Self.score(cost: 0, weight: lexicon.entry(for: lower)?.weight ?? 0.5)
            + learning.usageBoost(lower) + contextBonus(lower, after: previous)
        let probabilities = Self.softmax(
            typed: known ? (lower, typedScore) : nil,
            candidates: candidates
        )

        return SpellingResult(
            typed: typed,
            isKnownWord: known,
            candidates: candidates,
            completions: completions,
            autocorrect: autocorrect(typed: typed, lower: lower, known: known, candidates: candidates,
                                     learnedFix: learnedFix,
                                     typedScore: previous != nil && context != nil ? typedScore : nil,
                                     previous: previous, allowSplit: allowSplit),
            probabilities: probabilities
        )
    }

    static func score(cost: Double, weight: Double) -> Double {
        -1.6 * cost + 1.8 * weight
    }

    private func autocorrect(typed: String, lower: String, known: Bool, candidates: [Candidate],
                             learnedFix: (word: String, strength: Int)?, typedScore: Double?,
                             previous: String?, allowSplit: Bool) -> String? {
        // A fix the writer keeps choosing: once for a misspelling, twice for a real word ("luke" → like).
        if let fix = learnedFix, fix.strength >= (known ? 2 : 1) {
            return Casing.apply(from: typed, to: fix.word)
        }
        if isPersonal(lower) { return nil }
        if let fix = Self.apostropheFixes[lower], !learning.isRejected(lower, fix) {
            return Casing.apply(from: typed, to: fix)
        }
        if known && lexicon.entry(for: lower) == nil {
            // A rare word only the iPhone's dictionary knows ("som", "twi", "paries") is far
            // more likely a slip for a common word one key away. Anything else is left alone.
            guard let best = candidates.first, best.editCost <= 1.0, best.weight >= 0.5,
                  candidates.count < 2 || best.score - candidates[1].score >= 0.4,
                  !learning.isRejected(lower, best.word) else { return nil }
            return Casing.apply(from: typed, to: best.word)
        }
        if known {
            // A real word that doesn't fit the sentence, one slip away from one that
            // clearly does: "he us" → is, "going ti" → to.
            // (Look-alike homophones such as its/it's are left to Jev's look-back review.)
            // A slip or two away is also fine when the sentence makes it obvious ("we cab talk" → can).
            if let typedScore, Homophones.alternatives(for: lower).isEmpty, let swap = candidates.first(where: {
                let gain = $0.score - typedScore
                return ($0.editCost <= 0.6 && gain >= Self.realWordSwapMargin || $0.editCost <= 1.2 && gain >= 1.5)
                    && !learning.isRejected(lower, $0.word)
            }) {
                return Casing.apply(from: typed, to: swap.word)
            }
            // "i" → "I", "monday" → "Monday": only when the writer typed all lowercase,
            // and not when a much more common word is a slip away ("luke" is probably "like").
            if let entry = lexicon.entry(for: lower), entry.word != lower, typed == lower,
               !candidates.contains(where: { $0.editCost <= 1.0 && $0.weight > entry.weight + 0.05 }) {
                return entry.word
            }
            return nil
        }
        // A lone "j" is the "i" key just missed: "j am" → "I am".
        if lower == "j" { return "I" }
        guard lower.count >= 2 else { return nil }
        guard let best = candidates.first, !learning.isRejected(lower, best.word) else {
            return allowSplit ? splitFix(typed: typed, lower: lower, previous: previous)?.text : nil
        }
        let margin = candidates.count > 1 ? best.score - candidates[1].score : .infinity
        // Close spellings need a small lead; messier ones ("dkrd" → does) need the
        // sentence to point clearly at the word as well.
        let closeEnough = best.editCost <= 1.5 && margin >= 0.25
        let sentenceAgrees = best.editCost <= 2.2 && margin >= 0.5
            && contextBonus(best.word.lowercased(), after: previous) >= 0.4
        // Long words with several slips ("affommodatw" → accommodate) when nothing else is close.
        let longAndClear = lower.count >= 8 && best.editCost <= Double(lower.count) * 0.25 && margin >= 0.35
        let soundedOut = best.soundsAlike && best.editCost <= 1.2
        let split = allowSplit && !soundedOut ? splitFix(typed: typed, lower: lower, previous: previous) : nil
        // A sounded-out spelling ("explane") is one word, not two ("ex plane").
        if let split, !(closeEnough || longAndClear) || split.cost + 0.5 < best.editCost {
            return split.text
        }
        guard closeEnough || sentenceAgrees || longAndClear else { return nil }
        return Casing.apply(from: typed, to: best.word)
    }

    /// Two words run together, with the space missed or hit as a bottom-row letter
    /// beside the space bar: "inthe" → in the, "geybthis" → get this.
    func splitFix(typed: String, lower: String, previous: String?) -> (text: String, cost: Double)? {
        let chars = Array(lower)
        guard chars.count >= 4, chars.count <= 20, chars.allSatisfy({ $0.isLetter }) else { return nil }
        var best: (text: String, cost: Double)?
        for i in 1..<(chars.count - 1) {
            for replacesSpace in [false, true] {
                if replacesSpace && !"cvbnm".contains(chars[i]) { continue }
                let left = String(chars[..<i])
                let right = String(chars[(replacesSpace ? i + 1 : i)...])
                guard right.count >= 2, let rightEntry = lexicon.entry(for: right), rightEntry.weight >= 0.45,
                      left.count >= 2 || left == "a" || left == "i" else { continue }
                var cost = replacesSpace ? 0.4 : 0.3
                let leftWord: String
                if let entry = lexicon.entry(for: left), entry.weight >= 0.45 {
                    leftWord = entry.word
                } else if left.count >= 2 {
                    // One slip in the first word is fine ("gey" → get).
                    let fix = analyze(left, previous: previous, limit: 2, allowSplit: false)
                    guard !fix.isKnownWord, let first = fix.candidates.first, fix.autocorrect == first.word,
                          first.editCost <= 0.6, first.weight >= 0.45 else { continue }
                    leftWord = first.word
                    cost += first.editCost
                } else { continue }
                // The two words must make sense together.
                if context != nil, contextBonus(rightEntry.key, after: leftWord.lowercased()) <= 0 { continue }
                if best == nil || cost < best!.cost {
                    best = (Casing.apply(from: String(typed.prefix(left.count)), to: leftWord) + " " + rightEntry.word, cost)
                }
            }
        }
        return best
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
