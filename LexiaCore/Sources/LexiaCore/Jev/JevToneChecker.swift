import Foundation

/// How a message is likely to come across, from Jev.
public struct ToneVerdict: Sendable, Equatable {
    /// 0 = warm … 3 = could sound rude.
    public let level: Int
    public let label: String
    public let confidence: Double
    /// Probability that the message is unclear about what's being said or asked.
    public let unclear: Double

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
        ]
    }

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
        return ToneVerdict(level: level, label: Self.levels[level], confidence: confidence, unclear: unclear)
    }
}
