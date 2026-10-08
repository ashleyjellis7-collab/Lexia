import Foundation

/// What Lexia has learned about one person's writing. Kept on the device only.
///
/// * **Usage:** words you write often rank higher in suggestions.
/// * **Fixes:** when you pick a correction for a typo (`luke` → like), that
///   pairing is remembered. Once it has been chosen enough, the typo is fixed
///   automatically next time.
/// * **Rejections:** undoing an autocorrect (delete straight after it) counts
///   against that pairing, so Lexia stops making it.
public final class LearningModel: @unchecked Sendable {

    private struct Snapshot: Codable {
        var usage: [String: Int] = [:]
        var fixes: [String: [String: Int]] = [:]
        /// How often each unknown word was deliberately kept (optional for older saves).
        var keeps: [String: Int]? = nil
    }

    private let lock = NSLock()
    private var state = Snapshot()

    /// Number of changes since the model was created or last saved.
    public private(set) var unsavedChanges = 0

    static let maxUsageEntries = 6000
    static let maxFixEntries = 1500

    public init() {}

    public init(data: Data?) {
        if let data, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            state = snapshot
        }
    }

    /// Replaces everything learned with a stored copy (e.g. after a reset in the app).
    public func load(_ data: Data?) {
        let snapshot = data.flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
        lock.lock(); defer { lock.unlock() }
        state = snapshot
        unsavedChanges = 0
    }

    /// Serialised form for storage; resets `unsavedChanges`.
    public func save() -> Data {
        lock.lock(); defer { lock.unlock() }
        unsavedChanges = 0
        return (try? JSONEncoder().encode(state)) ?? Data()
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        state = Snapshot()
        unsavedChanges += 1
    }

    /// How many different words and fixes have been learned.
    public var summary: (words: Int, fixes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (state.usage.count, state.fixes.values.reduce(0) { $0 + $1.values.filter { $0 > 0 }.count })
    }

    private static func key(_ word: String) -> String {
        TextScanner.normalized(word).lowercased()
    }

    // MARK: - Recording

    /// The writer finished a word (after any correction).
    public func recordUse(_ word: String) {
        let k = Self.key(word)
        guard k.count >= 1, k.allSatisfy({ $0.isLetter || $0 == "'" }) else { return }
        lock.lock(); defer { lock.unlock() }
        state.usage[k, default: 0] += 1
        unsavedChanges += 1
        if state.usage.count > Self.maxUsageEntries {
            // Forget the rarest half.
            let keep = state.usage.sorted { $0.value > $1.value }.prefix(Self.maxUsageEntries / 2)
            state.usage = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    /// The writer chose `chosen` for what they typed (a picked suggestion or a kept autocorrect).
    public func recordCorrection(from typed: String, to chosen: String) {
        adjust(typed, chosen, by: 1)
    }

    /// The writer deliberately kept `word` as typed. Returns how many times they have.
    /// A word is only treated as "theirs" after being kept twice, so one slip doesn't teach a typo.
    @discardableResult
    public func recordKeep(_ word: String) -> Int {
        let k = Self.key(word)
        guard !k.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var keeps = state.keeps ?? [:]
        keeps[k, default: 0] += 1
        if keeps.count > 2000, let drop = keeps.keys.first(where: { $0 != k }) { keeps.removeValue(forKey: drop) }
        state.keeps = keeps
        unsavedChanges += 1
        return keeps[k] ?? 0
    }

    /// The writer undid the change from `typed` to `rejected`.
    public func recordRejection(from typed: String, to rejected: String) {
        adjust(typed, rejected, by: -2)
    }

    private func adjust(_ typed: String, _ chosen: String, by delta: Int) {
        let t = Self.key(typed)
        let chosenForm = TextScanner.normalized(chosen)
        guard !t.isEmpty, !chosenForm.isEmpty, t != chosenForm.lowercased() else { return }
        lock.lock(); defer { lock.unlock() }
        // Store the chosen word as written, so "I'm" keeps its capital.
        var options = state.fixes[t] ?? [:]
        let existing = options.keys.first { $0.lowercased() == chosenForm.lowercased() } ?? chosenForm
        options[existing] = max(-5, min(20, (options[existing] ?? 0) + delta))
        state.fixes[t] = options
        unsavedChanges += 1
        if state.fixes.count > Self.maxFixEntries, let drop = state.fixes.keys.first(where: { $0 != t }) {
            state.fixes.removeValue(forKey: drop)
        }
    }

    // MARK: - Using what was learned

    /// Score bonus (0…0.8) for a word the writer uses often.
    public func usageBoost(_ lowercasedWord: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        guard let count = state.usage[lowercasedWord], count > 0 else { return 0 }
        return min(0.8, 0.25 * log2(1 + Double(count)))
    }

    /// The correction the writer most often picks for `typed`, with how many
    /// times (net of undos) they've picked it.
    public func learnedFix(for typed: String) -> (word: String, strength: Int)? {
        lock.lock(); defer { lock.unlock() }
        guard let best = state.fixes[Self.key(typed)]?.max(by: { $0.value < $1.value }), best.value > 0 else {
            return nil
        }
        return (best.key, best.value)
    }

    /// The writer has undone `typed` → `candidate` more often than they kept it.
    public func isRejected(_ typed: String, _ candidate: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let options = state.fixes[Self.key(typed)] else { return false }
        return options.contains { $0.key.lowercased() == candidate.lowercased() && $0.value < 0 }
    }
}
