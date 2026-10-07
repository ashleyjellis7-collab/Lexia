import Foundation

/// A chip in the suggestion bar.
public struct Suggestion: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// Keep exactly what was typed (shown in quotes when a correction is pending).
        case keepTyped
        /// A spelling correction.
        case correction
        /// A word starting with the typed letters.
        case completion
        /// A correction for a word already typed, e.g. "their" → "there".
        case fixPrevious
        /// A likely next word, shown before you start typing one.
        case prediction
    }

    public let text: String
    public let kind: Kind
    /// Will be applied automatically when the writer presses space.
    public let isAutocorrect: Bool
    /// Jev was involved in choosing this.
    public let fromJev: Bool
    /// For `.fixPrevious`: the exact end of the text to replace, and its replacement.
    public let fix: TailFix?

    public var id: String { "\(kind.rawValue):\(text)" }

    public init(text: String, kind: Kind, isAutocorrect: Bool = false, fromJev: Bool = false, fix: TailFix? = nil) {
        self.text = text
        self.kind = kind
        self.isAutocorrect = isAutocorrect
        self.fromJev = fromJev
        self.fix = fix
    }
}

/// Replace `original` (the exact end of the text before the cursor) with `replacement`.
public struct TailFix: Sendable, Hashable {
    public let original: String
    public let replacement: String
    public let word: String
    public let correctedWord: String
}

/// Everything the suggestion bar needs for the word at the cursor.
public struct SuggestionSet: Sendable, Equatable {
    public enum Source: Sendable, Equatable { case device, jev }

    public let context: TypingContext
    public let suggestions: [Suggestion]
    /// What pressing space will change the word to (already respecting the autocorrect mode).
    public let autocorrect: String?
    public let source: Source
    let local: SpellingResult
}

/// How eagerly words are changed as you type.
public enum AutocorrectMode: String, Codable, Sendable, CaseIterable {
    /// Never change words; no suggestions.
    case off
    /// Show suggestions, never change words automatically.
    case suggestOnly
    /// Change words automatically only when confident (iOS-style, but more cautious).
    case whenConfident
}

/// Combines the on-device engine with Jev.
///
/// 1. `local(for:)` is instant and works offline/without Full Access.
/// 2. `refine(_:)` asks Jev to choose between the local candidates using the
///    whole sentence, and only lets it auto-change a word when Jev is
///    confident the typed word is wrong. Errors fall back to the local result.
/// 3. `reviewRecentWords(textBefore:)` looks back at the last words once the
///    next one is typed, so "their going" can be fixed when "going" arrives.
public final class SuggestionPipeline: @unchecked Sendable {

    public let engine: SpellingEngine
    public var reranker: JevReranker?
    public var mode: AutocorrectMode = .whenConfident

    /// Weight of Jev's opinion vs. the on-device score when blending.
    let jevWeight = 0.7

    private let cacheLock = NSLock()
    private var cache: [TypingContext: JevDecision] = [:]
    private var cacheOrder: [TypingContext] = []

    public init(engine: SpellingEngine, reranker: JevReranker? = nil) {
        self.engine = engine
        self.reranker = reranker
    }

    // MARK: - On-device

    public func local(for context: TypingContext) -> SuggestionSet {
        let result = engine.analyze(context.word, previous: TextScanner.previousWord(in: context.before),
                                    isDictionaryWord: context.isDictionaryWord)
        return compose(context: context, local: result, ranked: result.candidates.map(\.word),
                       autocorrect: result.autocorrect, source: .device)
    }

    /// Likely next words for when no word has been started yet.
    public func predictions(for context: TypingContext) -> [Suggestion] {
        guard mode != .off, context.word.isEmpty else { return [] }
        let previous = TextScanner.previousWord(in: context.before)
        let atSentenceStart = previous == ContextModel.sentenceStart
        return engine.predictions(after: previous).map { word in
            let shown = atSentenceStart ? word.prefix(1).uppercased() + word.dropFirst() : word
            return Suggestion(text: shown, kind: .prediction)
        }
    }

    // MARK: - Jev

    /// Whether asking Jev about this word could change anything.
    public func shouldAskJev(_ set: SuggestionSet) -> Bool {
        guard reranker != nil, mode != .off, set.context.word.count >= 2 else { return false }
        let local = set.local
        if engine.isKnown(local.typed) {
            if !Homophones.alternatives(for: local.typed).isEmpty { return true }
            // A real word with a much more common near-miss: "dab" vs "bad", "form" vs "from".
            let typedWeight = engine.lexicon.entry(for: local.typed)?.weight ?? 0
            return local.candidates.contains { $0.editCost <= 1.0 && $0.weight > typedWeight + 0.08 }
        }
        return !local.candidates.isEmpty
    }

    /// Returns a Jev-improved version of `set`, or `set` itself if Jev is
    /// unavailable, unsure, or fails.
    public func refine(_ set: SuggestionSet) async -> SuggestionSet {
        guard shouldAskJev(set), let options = options(for: set.local),
              let decision = await jevDecision(context: set.context, options: options) else { return set }

        let local = set.local
        let typedLower = local.typed.lowercased()
        let blended = blend(decision: decision, local: local, options: options)
        let ranked = blended.sorted { $0.value > $1.value }.map(\.key)
        guard let best = ranked.first, let bestProbability = blended[best] else { return set }

        // Jev can redirect or confirm a correction, but it only overrules the
        // on-device fix when it's sure the typed word was meant.
        let localFix = local.autocorrect?.lowercased()
        let jevKeepsTyped = best == typedLower && decision.typedIsIntended >= 0.85
        var autocorrect: String?
        if engine.isKnown(typedLower) {
            if best != typedLower, decision.typedIsIntended < 0.15, decision.choice == best,
               decision.confidence >= 0.85 {
                // Real-word mix-up ("form" → from) that Jev is very sure about.
                autocorrect = best
            } else if !jevKeepsTyped {
                autocorrect = localFix   // "i" → "I", "dont" → "don't", learned fixes
            }
        } else if best != typedLower, bestProbability >= 0.4, !engine.learning.isRejected(typedLower, best) {
            autocorrect = best
        } else if !jevKeepsTyped {
            autocorrect = localFix
        }

        let display = displayForms(local: local)
        return compose(
            context: set.context,
            local: local,
            ranked: ranked.filter { $0 != typedLower }.map { display[$0] ?? $0 },
            autocorrect: autocorrect.map { display[$0] ?? $0 }.map { Casing.apply(from: local.typed, to: $0) },
            source: .jev
        )
    }

    /// Looks back at the last two words for a mistake that only became
    /// obvious with more context. Returns a fix chip, or nil.
    public func reviewRecentWords(textBefore: String) async -> Suggestion? {
        guard reranker != nil, mode != .off else { return nil }
        let ranges = TextScanner.wordRanges(in: textBefore).suffix(2).reversed()
        for range in ranges {
            let word = String(textBefore[range])
            let lower = TextScanner.normalized(word).lowercased()
            let alternatives = Homophones.alternatives(for: lower)
            guard word.count >= 2, !alternatives.isEmpty else { continue }

            let context = TypingContext(
                before: String(textBefore[..<range.lowerBound]),
                word: word,
                after: String(textBefore[range.upperBound...])
            )
            let options = [lower] + alternatives
            guard let decision = await jevDecision(context: context, options: options),
                  decision.choice != lower, options.contains(decision.choice),
                  decision.typedIsIntended < 0.2, decision.confidence >= 0.75 else { continue }

            let corrected = Casing.apply(from: word, to: decision.choice)
            let original = String(textBefore[range.lowerBound...])
            let replacement = corrected + String(textBefore[range.upperBound...])
            return Suggestion(
                text: corrected, kind: .fixPrevious, fromJev: true,
                fix: TailFix(original: original, replacement: replacement, word: word, correctedWord: corrected)
            )
        }
        return nil
    }

    // MARK: - Helpers

    private func options(for local: SpellingResult) -> [String]? {
        let typed = local.typed.lowercased()
        // A misspelling isn't offered as an option: Jev picks which real word was meant.
        var options = engine.isKnown(typed) ? [typed] : []
        for word in Homophones.alternatives(for: typed) + local.candidates.map({ $0.word.lowercased() })
        where !options.contains(word) && word != typed {
            options.append(word)
        }
        if let fix = local.autocorrect?.lowercased(), !options.contains(fix) { options.append(fix) }
        options = Array(options.prefix(7))
        return options.count > 1 ? options : nil
    }

    private func displayForms(local: SpellingResult) -> [String: String] {
        var display: [String: String] = [:]
        for candidate in local.candidates { display[candidate.word.lowercased()] = candidate.word }
        if let fix = local.autocorrect { display[fix.lowercased()] = fix }
        return display
    }

    private func blend(decision: JevDecision, local: SpellingResult, options: [String]) -> [String: Double] {
        let localTotal = options.reduce(0) { $0 + (local.probabilities[$1] ?? 0) }
        var blended: [String: Double] = [:]
        for option in options {
            let localP = localTotal > 0 ? (local.probabilities[option] ?? 0) / localTotal : 0
            blended[option] = jevWeight * (decision.probabilities[option] ?? 0) + (1 - jevWeight) * localP
        }
        return blended
    }

    private func jevDecision(context: TypingContext, options: [String]) async -> JevDecision? {
        if let cached = cachedDecision(for: context) { return cached }
        guard let reranker, let decision = try? await reranker.decide(context: context, options: options) else {
            return nil
        }
        storeDecision(decision, for: context)
        return decision
    }

    // Locking lives in synchronous helpers: NSLock mustn't be used directly in async code.
    private func cachedDecision(for context: TypingContext) -> JevDecision? {
        cacheLock.lock(); defer { cacheLock.unlock() }
        return cache[context]
    }

    private func storeDecision(_ decision: JevDecision, for context: TypingContext) {
        cacheLock.lock(); defer { cacheLock.unlock() }
        cache[context] = decision
        cacheOrder.append(context)
        if cacheOrder.count > 64 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    /// Lays out the bar: [keep typed] [best] [next], respecting the mode.
    func compose(context: TypingContext, local: SpellingResult, ranked: [String],
                 autocorrect proposed: String?, source: SuggestionSet.Source) -> SuggestionSet {
        guard mode != .off, !context.word.isEmpty else {
            return SuggestionSet(context: context, suggestions: [], autocorrect: nil, source: source, local: local)
        }
        let autocorrect = mode == .whenConfident ? proposed : nil
        let typed = local.typed
        var suggestions: [Suggestion] = []
        var seen: Set<String> = [typed.lowercased()]

        func add(_ text: String, _ kind: Suggestion.Kind, auto: Bool = false) {
            guard suggestions.count < 3, seen.insert(text.lowercased()).inserted else { return }
            suggestions.append(Suggestion(text: text, kind: kind, isAutocorrect: auto, fromJev: source == .jev))
        }

        suggestions.append(Suggestion(text: typed, kind: .keepTyped, fromJev: source == .jev))
        if let autocorrect, autocorrect != typed {
            seen.remove(autocorrect.lowercased())
            add(autocorrect, .correction, auto: true)
        }
        let corrections = ranked.map { Casing.apply(from: typed, to: $0) }
        let completions = local.completions.map { Casing.apply(from: typed, to: $0) }
        if local.isKnownWord && source == .device {
            completions.forEach { add($0, .completion) }
            corrections.forEach { add($0, .correction) }
        } else {
            corrections.forEach { add($0, .correction) }
            completions.forEach { add($0, .completion) }
        }
        return SuggestionSet(context: context, suggestions: suggestions, autocorrect: autocorrect,
                             source: source, local: local)
    }
}
