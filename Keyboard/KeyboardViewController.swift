import UIKit
import SwiftUI
import AVFoundation
import LexiaCore

/// The Lexia keyboard extension.
///
/// Typing flow:
/// * every keystroke gets instant on-device suggestions (works offline and
///   without Full Access);
/// * after a short pause, Jev re-ranks them using the sentence;
/// * space/punctuation applies the autocorrect only if one is confident;
/// * backspace straight after an autocorrect puts the original back (and
///   remembers that word);
/// * after each word, Jev looks back for mixed-up words like their/there and
///   offers a ↺ fix chip — it never changes earlier words on its own.
final class KeyboardViewController: UIInputViewController {

    private let state = KeyboardState()
    private var pipeline: SuggestionPipeline?
    private var suggestionTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?

    private var lastAutocorrection: (original: String, replacement: String, terminator: String)?
    /// Where each letter of the current word was touched (for finger-slip correction).
    private var touchLog: [KeyTouch] = []
    /// After delete removes the space following an autocorrect, offers the original back.
    private var pendingUndo: (original: String, replacement: String)?
    private var lastSpace: Date?
    private var lastShiftTap: Date?
    private let speech = AVSpeechSynthesizer()
    private let haptics = UIImpactFeedbackGenerator(style: .light)

    private let learning = LearningModel(data: SettingsStore.shared.learningData)

    /// The lexicon is loaded once per extension process.
    private static var sharedLexicon: Lexicon?
    private static var sharedContext: ContextModel?

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        FontRegistry.registerBundledFonts()
        state.settings = SettingsStore.shared.load()
        state.inputController = self
        state.onKey = { [weak self] in self?.handle($0) }
        state.onSuggestion = { [weak self] in self?.select($0) }
        state.onSpeak = { [weak self] in self?.speak($0) }

        let host = UIHostingController(rootView: KeyboardView(state: state))
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(host)
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        let height = view.heightAnchor.constraint(equalToConstant: KeyboardView.totalHeight)
        height.priority = UILayoutPriority(999)
        height.isActive = true

        loadPipeline()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Pick up anything changed in the Lexia app since last time.
        state.settings = SettingsStore.shared.load()
        pipeline?.mode = state.settings.autocorrectMode
        pipeline?.engine.learn(SettingsStore.shared.personalWords)
        reloadLearningIfNeeded()
        configureJev()
        updateTraits()
        updateAutoShift()
        refresh()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        saveLearning(force: true)
    }

    // MARK: - Learning

    /// Reloads what was learned, picking up a reset made in the Lexia app.
    /// (Anything new was saved when the keyboard last disappeared.)
    private func reloadLearningIfNeeded() {
        if learning.unsavedChanges == 0 { learning.load(SettingsStore.shared.learningData) }
    }

    private func saveLearning(force: Bool = false) {
        guard force ? learning.unsavedChanges > 0 : learning.unsavedChanges >= 15 else { return }
        SettingsStore.shared.learningData = learning.save()
    }

    /// Don't learn from (or send) text typed into sensitive fields.
    private var learningAllowedHere: Bool { jevAllowedHere }

    private func noteUse(_ word: String) {
        guard learningAllowedHere, !word.isEmpty else { return }
        learning.recordUse(word)
        saveLearning()
    }

    private func noteCorrection(from typed: String, to chosen: String) {
        guard learningAllowedHere, !typed.isEmpty else { return }
        learning.recordCorrection(from: typed, to: chosen)
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        if state.showsGlobe != needsInputModeSwitchKey { state.showsGlobe = needsInputModeSwitchKey }
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        updateTraits()
        updateAutoShift()
        refresh()
    }

    private func loadPipeline() {
        if let lexicon = Self.sharedLexicon {
            makePipeline(lexicon)
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let lexicon = try? Lexicon.bundledEnglish() else { return }
            let context = try? ContextModel.bundledEnglish()
            await self?.didLoad(lexicon, context: context)
        }
    }

    private func didLoad(_ lexicon: Lexicon, context: ContextModel?) {
        Self.sharedLexicon = lexicon
        Self.sharedContext = context
        makePipeline(lexicon)
    }

    private func makePipeline(_ lexicon: Lexicon) {
        let engine = SpellingEngine(lexicon: lexicon, personalWords: SettingsStore.shared.personalWords,
                                    learning: learning)
        engine.context = Self.sharedContext
        cleanUpPersonalWordsOnce(engine)
        let pipeline = SuggestionPipeline(engine: engine)
        pipeline.mode = state.settings.autocorrectMode
        self.pipeline = pipeline
        configureJev()
        // Contact names and text-replacement shortcuts are never "misspelled".
        requestSupplementaryLexicon { lexicon in
            engine.learn(lexicon.entries.map(\.userInput))
        }
        refresh()
    }

    private func configureJev() {
        guard let pipeline else { return }
        let settings = state.settings
        guard settings.useJev, settings.autocorrectMode != .off else {
            pipeline.reranker = nil
            state.notice = nil
            return
        }
        guard hasFullAccess else {
            pipeline.reranker = nil
            state.notice = "Turn on “Allow Full Access” for Lexia to get Jev smart corrections."
            return
        }
        guard let key = KeychainStore.readAPIKey(), let url = URL(string: settings.jevBaseURL) else {
            pipeline.reranker = nil
            state.notice = "Add your TypeSafe API key in the Lexia app for smart corrections."
            return
        }
        let configuration = JevConfiguration(apiKey: key, baseURL: url, model: settings.jevModel)
        pipeline.reranker = JevReranker(client: JevClient(configuration: configuration))
        state.notice = nil
    }

    /// Never send text from sensitive fields to Jev.
    private var jevAllowedHere: Bool {
        let proxy = textDocumentProxy
        if proxy.keyboardType == .URL || proxy.keyboardType == .emailAddress { return false }
        let contentType: UITextContentType? = proxy.textContentType ?? nil
        if let type = contentType {
            let sensitive: [UITextContentType] = [
                .password, .newPassword, .oneTimeCode, .creditCardNumber, .emailAddress, .username,
                .telephoneNumber, .URL,
            ]
            if sensitive.contains(type) { return false }
        }
        return true
    }

    private var autocorrectAllowedHere: Bool {
        textDocumentProxy.autocorrectionType != .no
            && state.settings.autocorrectMode == .whenConfident
            && textDocumentProxy.keyboardType != .URL
            && textDocumentProxy.keyboardType != .emailAddress
    }

    // MARK: - Suggestions

    private let textChecker = UITextChecker()

    /// Uses the iPhone's own dictionary, which knows far more words than Lexia's list.
    private func isDictionaryWord(_ word: String) -> Bool {
        guard word.count > 1 else { return false }
        let range = NSRange(location: 0, length: (word as NSString).length)
        return ["en_GB", "en_US"].contains { language in
            UITextChecker.availableLanguages.contains(language)
                && textChecker.rangeOfMisspelledWord(in: word, range: range, startingAt: 0, wrap: false,
                                                     language: language).location == NSNotFound
        }
    }

    private func currentContext() -> TypingContext {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let after = textDocumentProxy.documentContextAfterInput ?? ""
        let word = TextScanner.trailingWord(in: before)
        // Only trust the touch log if it matches the word letter for letter (the cursor may have moved).
        let touches = touchLog.map(\.letter) == Array(word.lowercased()) ? touchLog : []
        return TypingContext(before: String(before.dropLast(word.count)), word: word, after: after,
                             isDictionaryWord: isDictionaryWord(word), touches: touches)
    }

    private func refresh() {
        suggestionTask?.cancel()
        let context = currentContext()
        if let undo = pendingUndo, context.word != undo.replacement { pendingUndo = nil }
        if let fix = state.reviewFix?.fix, !context.before.hasSuffix(fix.original) {
            state.reviewFix = nil
        }
        guard let pipeline, !context.word.isEmpty, state.settings.autocorrectMode != .off else {
            state.currentSet = nil
            state.jevWorking = false
            showPredictions(context)
            return
        }
        let askJev = pipeline.reranker != nil && jevAllowedHere

        suggestionTask = Task { [weak self] in
            let local = await Task.detached(priority: .userInitiated) { pipeline.local(for: context) }.value
            guard let self, !Task.isCancelled, self.currentContext() == context else { return }
            self.show(local)

            guard askJev, pipeline.shouldAskJev(local) else { return }
            // Wait for a pause in typing so we don't call Jev on every letter.
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            self.state.jevWorking = true
            defer { self.state.jevWorking = false }
            let refined = await pipeline.refine(local)
            guard !Task.isCancelled, self.currentContext() == context else { return }
            self.show(refined)
        }
    }

    private func show(_ set: SuggestionSet) {
        state.currentSet = set
        var chips = set.suggestions
        if let fix = state.reviewFix { chips = [fix] + chips.prefix(2) }
        if let undo = pendingUndo, set.context.word == undo.replacement {
            chips = [Suggestion(text: undo.original, kind: .undoCorrection)]
                + chips.filter { $0.kind != .keepTyped }.prefix(2)
        }
        state.suggestions = chips
    }

    private func redisplay() {
        if let set = state.currentSet, set.context == currentContext() {
            show(set)
        } else {
            showPredictions(currentContext())
        }
    }

    /// Before a word is started: a pending ↺ fix, then likely next words.
    private func showPredictions(_ context: TypingContext) {
        var chips: [Suggestion] = state.reviewFix.map { [$0] } ?? []
        if context.word.isEmpty, let pipeline {
            chips += pipeline.predictions(for: context).prefix(3 - chips.count)
        }
        state.suggestions = chips
    }

    /// After a word is finished, ask Jev whether one of the last two words was
    /// a mix-up that only the following words reveal ("their going").
    private func scheduleReview() {
        reviewTask?.cancel()
        state.reviewFix = nil
        guard state.settings.reviewPreviousWords, let pipeline, pipeline.reranker != nil, jevAllowedHere else { return }
        let before = String((textDocumentProxy.documentContextBeforeInput ?? "").suffix(300))
        reviewTask = Task { [weak self] in
            guard let fix = await pipeline.reviewRecentWords(textBefore: before),
                  let self, !Task.isCancelled, let tail = fix.fix,
                  self.currentContext().before.hasSuffix(tail.original) else { return }
            self.state.reviewFix = fix
            self.redisplay()
        }
    }

    // MARK: - Keys

    private func handle(_ key: KeyKind) {
        if hasFullAccess && state.settings.keyVibration { haptics.impactOccurred() }
        if key != .space { lastSpace = nil }
        switch key {
        case .character(let s):
            insertCharacter(s)
        case .shift:
            toggleShift()
            return
        case .backspace:
            backspace()
        case .space:
            space()
        case .returnKey:
            commitWord(terminator: "\n")
        case .page(let page, _):
            state.page = page
            return
        case .globe:
            return
        }
        updateAutoShift()
        refresh()
    }

    private func insertCharacter(_ s: String) {
        if [".", ",", "?", "!", ";", ":"].contains(s) {
            commitWord(terminator: s)
            return
        }
        if TextScanner.trailingWord(in: textDocumentProxy.documentContextBeforeInput ?? "").isEmpty { touchLog = [] }
        if let letter = s.first, s.count == 1, TextScanner.isWordCharacter(letter) {
            let touch = state.lastTouch ?? .zero
            touchLog.append(KeyTouch(letter: letter, dx: Double(touch.x), dy: Double(touch.y)))
        }
        state.lastTouch = nil
        let text = state.shift == .off ? s : s.uppercased()
        textDocumentProxy.insertText(text)
        lastAutocorrection = nil
    }

    private func space() {
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        // Double space → full stop.
        if let last = lastSpace, Date().timeIntervalSince(last) < 0.5,
           before.hasSuffix(" "), let prior = before.dropLast().last, prior.isLetter || prior.isNumber {
            textDocumentProxy.deleteBackward()
            textDocumentProxy.insertText(". ")
            lastSpace = nil
            lastAutocorrection = nil
            return
        }
        commitWord(terminator: " ")
        lastSpace = Date()
        if state.page != .letters { state.page = .letters }
    }

    /// Finishes the current word with `terminator`, autocorrecting it if confident.
    private func commitWord(terminator: String) {
        let context = currentContext()
        defer { touchLog = [] }
        // "a d" → "and": the space bar was hit instead of a nearby letter.
        if autocorrectAllowedHere, let fix = pipeline?.spaceSlipFix(before: context.before, word: context.word),
           (textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(fix.original) {
            for _ in 0..<fix.original.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(fix.replacement + terminator)
            lastAutocorrection = (fix.original, fix.replacement, terminator)
            noteUse(fix.replacement)
            scheduleReview()
            return
        }
        var replacement: String?
        if !context.word.isEmpty, autocorrectAllowedHere, let pipeline {
            let set = state.currentSet?.context == context ? state.currentSet : Optional(pipeline.local(for: context))
            replacement = set?.autocorrect
        }
        if let replacement, replacement != context.word {
            for _ in 0..<context.word.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(replacement + terminator)
            lastAutocorrection = (context.word, replacement, terminator)
            noteCorrection(from: context.word, to: replacement)
            noteUse(replacement)
        } else {
            textDocumentProxy.insertText(terminator)
            lastAutocorrection = nil
            noteUse(context.word)
        }
        if !context.word.isEmpty {
            applyLookBackFix()
            scheduleReview()
        }
    }

    /// Fixes the word before the one just finished when its neighbours make
    /// the mix-up obvious ("lived their until" → there). Delete undoes it.
    private func applyLookBackFix() {
        guard autocorrectAllowedHere, let pipeline else { return }
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        guard let fix = pipeline.localLookBackFix(textBefore: String(before.suffix(300))),
              before.hasSuffix(fix.original) else { return }
        for _ in 0..<fix.original.count { textDocumentProxy.deleteBackward() }
        textDocumentProxy.insertText(fix.replacement)
        lastAutocorrection = (fix.original, fix.replacement, "")
    }

    private func backspace() {
        // Backspace right after an autocorrect restores what was typed.
        if let c = lastAutocorrection,
           (textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(c.replacement + c.terminator) {
            if !c.original.contains(" "), !c.replacement.contains(" "), c.terminator.count == 1 {
                // Like Apple's keyboard: just delete the space and offer "↩ original" in the bar,
                // so deleting to add a letter doesn't undo (and learn) the typo.
                lastAutocorrection = nil
                textDocumentProxy.deleteBackward()
                pendingUndo = (c.original, c.replacement)
                return
            }
            for _ in 0..<(c.replacement.count + c.terminator.count) { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(c.original)
            lastAutocorrection = nil
            // For look-back fixes the first word is the one that was changed ("their until" → "there until").
            let originalWord = String(c.original.split(separator: " ").first ?? "")
            let replacementWord = String(c.replacement.split(separator: " ").first ?? "")
            if learningAllowedHere { learning.recordRejection(from: originalWord, to: replacementWord) }
            return
        }
        lastAutocorrection = nil
        if !touchLog.isEmpty { touchLog.removeLast() }
        textDocumentProxy.deleteBackward()
    }

    private func toggleShift() {
        let now = Date()
        if let last = lastShiftTap, now.timeIntervalSince(last) < 0.35 {
            state.shift = .capsLock
            lastShiftTap = nil
            return
        }
        lastShiftTap = now
        state.shift = state.shift == .off ? .on : .off
    }

    private func updateAutoShift() {
        guard state.shift != .capsLock else { return }
        let capitalization = textDocumentProxy.autocapitalizationType ?? .sentences
        let before = textDocumentProxy.documentContextBeforeInput ?? ""
        let shouldCapitalize: Bool
        switch capitalization {
        case .allCharacters:
            shouldCapitalize = true
        case .words:
            shouldCapitalize = before.isEmpty || before.last?.isWhitespace == true
        case .sentences:
            let trimmed = before.trimmingCharacters(in: .whitespaces)
            shouldCapitalize = before.isEmpty || before.hasSuffix("\n")
                || (before.last == " " && (trimmed.isEmpty || [".", "?", "!"].contains(trimmed.last!)))
        default:
            shouldCapitalize = false
        }
        state.shift = shouldCapitalize ? .on : .off
    }

    private func updateTraits() {
        let label: String
        switch textDocumentProxy.returnKeyType ?? .default {
        case .go: label = "go"
        case .search, .google, .yahoo: label = "search"
        case .send: label = "send"
        case .done: label = "done"
        case .next: label = "next"
        case .join: label = "join"
        case .route: label = "route"
        case .continue: label = "continue"
        case .emergencyCall: label = "SOS"
        default: label = "return"
        }
        if state.returnLabel != label { state.returnLabel = label }
    }

    // MARK: - Suggestion bar

    private func select(_ suggestion: Suggestion) {
        let context = currentContext()
        switch suggestion.kind {
        case .fixPrevious:
            if let fix = suggestion.fix {
                let tail = fix.original + context.word
                if (textDocumentProxy.documentContextBeforeInput ?? "").hasSuffix(tail) {
                    for _ in 0..<tail.count { textDocumentProxy.deleteBackward() }
                    textDocumentProxy.insertText(fix.replacement + context.word)
                    noteCorrection(from: fix.word, to: fix.correctedWord)
                }
            }
            state.reviewFix = nil
        case .keepTyped:
            keep(context.word)
            textDocumentProxy.insertText(" ")
            lastAutocorrection = nil
        case .undoCorrection:
            if let undo = pendingUndo, context.word == undo.replacement {
                for _ in 0..<undo.replacement.count { textDocumentProxy.deleteBackward() }
                textDocumentProxy.insertText(undo.original + " ")
                if learningAllowedHere { learning.recordRejection(from: undo.original, to: undo.replacement) }
                keep(undo.original)
            }
            pendingUndo = nil
        case .prediction:
            textDocumentProxy.insertText(suggestion.text + " ")
            lastAutocorrection = nil
            noteUse(suggestion.text)
        case .correction, .completion:
            for _ in 0..<context.word.count { textDocumentProxy.deleteBackward() }
            textDocumentProxy.insertText(suggestion.text + " ")
            lastAutocorrection = nil
            if suggestion.kind == .correction { noteCorrection(from: context.word, to: suggestion.text) }
            noteUse(suggestion.text)
            scheduleReview()
        }
        updateAutoShift()
        refresh()
    }

    /// The writer chose their own spelling. It only becomes one of "My words"
    /// after being kept twice and if it looks like a word, so slips aren't learned.
    private func keep(_ word: String) {
        guard learningAllowedHere, !word.isEmpty else { return }
        noteUse(word)
        guard let engine = pipeline?.engine, !engine.isKnown(word) else { return }
        if learning.recordKeep(word) >= 2, Self.looksLikeWord(word) { learn(word) }
    }

    static func looksLikeWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        guard lower.contains(where: { "aeiouy".contains($0) }) else { return word.count > 1 && word == word.uppercased() }
        let unlikely = ["wj", "jw", "jy", "yj", "jk", "kj", "jg", "gj", "jb", "bj", "jx", "xj", "vj", "jv", "qz", "zq",
                        "xz", "zx", "qw", "wq", "fq", "qf", "jq", "qj", "vq", "qv", "zj", "jz", "jh", "hj"]
        return !unlikely.contains { lower.contains($0) }
    }

    /// One-time tidy-up of words learned by the old, over-eager rules:
    /// keyboard-mash and near-misses of common words ("passprt", "peopl").
    private func cleanUpPersonalWordsOnce(_ engine: SpellingEngine) {
        let store = SettingsStore.shared
        guard !store.didCleanPersonalWords else { return }
        for word in store.personalWords {
            let isAcronym = word.count > 1 && word == word.uppercased()
            let nearMiss = engine.analyze(word.lowercased()).candidates.first.map { $0.editCost <= 1.0 && $0.weight >= 0.4 } ?? false
            if !isAcronym && (!Self.looksLikeWord(word) || nearMiss) {
                store.removePersonalWord(word)
                engine.forget(word)
            }
        }
        store.didCleanPersonalWords = true
    }

    private func learn(_ word: String) {
        guard !word.isEmpty else { return }
        pipeline?.engine.learn([word])
        SettingsStore.shared.addPersonalWord(word)
    }

    private func speak(_ text: String) {
        guard state.settings.speakSuggestions else { return }
        speech.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        speech.speak(utterance)
    }
}
