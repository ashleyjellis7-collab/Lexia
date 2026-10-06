import Foundation

/// The text around the word being typed.
public struct TypingContext: Sendable, Hashable {
    /// Text before the word (trimmed to the last few sentences).
    public var before: String
    /// The word at the cursor, as typed.
    public var word: String
    /// Text after the cursor, if any.
    public var after: String

    public init(before: String, word: String, after: String = "") {
        self.before = String(before.suffix(300))
        self.word = word
        self.after = String(after.prefix(120))
    }
}

/// Jev's verdict on which word the writer meant.
public struct JevDecision: Sendable, Equatable {
    /// Probability per option (lowercase), from Jev's `choice` answer.
    public let probabilities: [String: Double]
    /// Jev's pick.
    public let choice: String
    /// Jev's confidence in its pick.
    public let confidence: Double
    /// Probability that the word, exactly as typed, is what the writer meant.
    public let typedIsIntended: Double
}

/// Asks Jev to choose between the spelling engine's candidates, using the
/// sentence the word sits in. This is where context-only mistakes get caught:
/// "their going", "form the shop", "I saw a dab dog".
public struct JevReranker: Sendable {
    public let client: JevClient

    public init(client: JevClient) {
        self.client = client
    }

    static let task = """
        A person with dyslexia is typing on a phone keyboard. Decide which word they meant to write \
        at typed_word. Dyslexic spelling is often phonetic (becuz → because, fone → phone), swaps \
        letters (form/from, wiht/with), mirrors letters (b/d, p/q), drops or doubles letters \
        (litle/little), or picks the wrong homophone (their/there/they're, to/too/two).
        """

    /// Builds the System One request for a context and its options.
    public static func questions(typed: String, options: [String]) -> [String: JevQuestion] {
        var criteria: [String: String?] = [:]
        for option in options {
            // updateValue, not subscript assignment: assigning nil would drop the key.
            let description: String? = option == typed.lowercased() ? "Keep \"\(typed)\" exactly as typed" : nil
            criteria.updateValue(description, forKey: option)
        }
        return [
            "intended_word": .choice(
                instructions: "Which option is the word the writer meant at typed_word, given text_before and text_after? Pick the option that makes the sentence say what they most plausibly meant.",
                options: criteria
            ),
            "typed_is_intended": .noul(
                instructions: "Is typed_word, spelled exactly as it is, the word the writer intended in this sentence?",
                whenTrue: "The typed word is correct here and should not be changed",
                whenFalse: "The typed word is a misspelling or the wrong word for this sentence"
            ),
        ]
    }

    public static func state(for context: TypingContext) -> JSONValue {
        .object([
            "task": .string(task),
            "text_before": .string(context.before),
            "typed_word": .string(context.word),
            "text_after": .string(context.after),
        ])
    }

    /// Asks Jev to choose between `options` (lowercase words, the typed word included).
    public func decide(context: TypingContext, options: [String]) async throws -> JevDecision {
        let response = try await client.systemOne(
            state: Self.state(for: context),
            questions: Self.questions(typed: context.word, options: options)
        )
        guard case let .choice(label, confidence, probabilities)? = response.answers["intended_word"] else {
            throw JevError.missingAnswer("intended_word")
        }
        guard case let .noul(typedIsIntended)? = response.answers["typed_is_intended"] else {
            throw JevError.missingAnswer("typed_is_intended")
        }
        var cleaned: [String: Double] = [:]
        for option in options { cleaned[option] = probabilities[option] ?? 0 }
        if cleaned.values.allSatisfy({ $0 == 0 }) { cleaned[label] = confidence }
        return JevDecision(probabilities: cleaned, choice: label, confidence: confidence,
                           typedIsIntended: typedIsIntended)
    }
}
