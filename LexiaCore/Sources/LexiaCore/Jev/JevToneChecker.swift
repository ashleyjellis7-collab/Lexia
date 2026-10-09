import Foundation

/// How a message is likely to come across, from Jev.
public struct ToneVerdict: Sendable, Equatable {
    /// 0 = warm … 3 = could sound rude.
    public let level: Int
    public let label: String
    public let confidence: Double
    /// Probability that the message is unclear about what's being said or asked.
    public let unclear: Double
    /// Short, friendly endings Jev picked for this message ("Thanks!"), best first.
    /// Lexia only ever adds one of these if the writer taps it; their words are never changed.
    public var additions: [String] = []

    /// A one-line summary for the suggestion bar.
    public var summary: String {
        unclear >= 0.6 ? "\(label) · might be unclear" : label
    }
}

/// A one-tap tone check before sending. Jev only judges the message; it never
/// rewrites it, so nothing is added or changed.
public struct JevToneChecker: Sendable {
    public let client: JevClient

    public init(client: JevClient) {
        self.client = client
    }

    public static let levels = [
        "Sounds warm and friendly",
        "Sounds clear and neutral",
        "Could sound a bit abrupt",
        "Could sound annoyed or rude",
    ]

    public static func questions() -> [String: JevQuestion] {
        [
            "tone": .score(
                instructions: "How is this message likely to come across to the person reading it?",
                levels: levels.map { Optional($0) }
            ),
            "unclear": .noul(
                instructions: "Would the reader be unsure what the writer is saying or asking them to do?"
            ),
            "addition": .choice(
                instructions: "Which short ending, added after the message, would make it come across best to the reader?",
                options: Self.additionOptions
            ),
        ]
    }

    /// Endings Jev can suggest, with what each is for. "(nothing)" means the message is fine as it is.
    public static let additionOptions: [String: String?] = [
        "Thanks!": "Thanks them; suits a request or a reply to help",
        "Thank you so much!": "Warm, heartfelt thanks",
        "Hope that's OK.": "Softens a request, a change of plan or bad news",
        "No worries if not.": "Makes a request feel optional and low-pressure",
        "Sorry for the trouble.": "Apologises for causing work or a problem",
        "Let me know what you think.": "Invites a reply or an opinion",
        "Have a great day!": "A friendly sign-off",
        "Hope you're well.": "A caring line for a more formal or long-gap message",
        "😊": "A smile that lightens a short or blunt message",
        Self.nothing: "The message already reads well and needs nothing added",
    ]
    public static let nothing = "(nothing)"

    public func check(_ message: String) async throws -> ToneVerdict {
        let state: JSONValue = .object([
            "task": .string("A person with dyslexia wrote this message and wants to know how it will come across before sending it."),
            "message": .string(String(message.suffix(1500))),
        ])
        let response = try await client.systemOne(state: state, questions: Self.questions())
        guard case let .score(value, confidence, _)? = response.answers["tone"] else {
            throw JevError.missingAnswer("tone")
        }
        var unclear = 0.0
        if case let .noul(probability)? = response.answers["unclear"] { unclear = probability }
        let level = max(0, min(Self.levels.count - 1, Int(value.rounded())))
        var verdict = ToneVerdict(level: level, label: Self.levels[level], confidence: confidence, unclear: unclear)
        if case let .choice(_, _, probabilities)? = response.answers["addition"],
           (probabilities[Self.nothing] ?? 0) < 0.6 {
            let lowered = message.lowercased()
            verdict.additions = probabilities
                .filter { $0.key != Self.nothing && $0.value >= 0.1 && Self.additionOptions[$0.key] != nil }
                .filter { !lowered.contains($0.key.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
                .sorted { $0.value > $1.value }
                .prefix(2).map(\.key)
        }
        return verdict
    }
}

/// How to add a suggested ending to the end of a message without touching the writer's words.
public enum MessageEnding {
    public struct Edit: Equatable, Sendable {
        /// Trailing spaces to delete first.
        public let deleteCount: Int
        public let insert: String
    }

    private static let questionStarts: Set<String> = [
        "can", "could", "would", "will", "do", "does", "did", "are", "is", "was", "were", "what", "when",
        "where", "why", "how", "who", "which", "shall", "should", "have", "has", "may", "am", "any",
    ]

    /// The edit that adds `addition` after `text`: closes the last sentence with "." or "?"
    /// if it has no punctuation, then adds the ending after a space.
    public static func edit(adding addition: String, after text: String) -> Edit {
        var trimmed = Substring(text)
        while let last = trimmed.last, last == " " { trimmed = trimmed.dropLast() }
        let deleteCount = text.count - trimmed.count
        guard let last = trimmed.last else { return Edit(deleteCount: deleteCount, insert: addition) }
        if last == "\n" { return Edit(deleteCount: deleteCount, insert: addition) }
        var insert = ""
        if last.isLetter || last.isNumber {
            let sentence = trimmed.split(whereSeparator: { ".!?\n".contains($0) }).last ?? trimmed
            let firstWord = sentence.split(separator: " ").first.map { $0.lowercased() } ?? ""
            insert = questionStarts.contains(firstWord) ? "?" : "."
        }
        return Edit(deleteCount: deleteCount, insert: insert + " " + addition)
    }
}
