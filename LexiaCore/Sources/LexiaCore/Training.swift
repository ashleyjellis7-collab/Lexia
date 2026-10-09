import Foundation

// Support for the Train tab: practice sentences, word-by-word scoring, and
// the keyboard's private log of what was typed during a training round.

/// One finished word, recorded by the keyboard only while the Train tab is open.
public struct TrainingEvent: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable {
        /// Lexia changed the word automatically.
        case autocorrected
        /// The word was left as typed.
        case kept
        /// A suggestion was tapped.
        case picked
        /// An autocorrect was undone with ↩.
        case undone
    }

    /// The letters as typed.
    public let typed: String
    /// What ended up in the text.
    public let result: String
    public let action: Action
    public let date: Date

    public init(typed: String, result: String, action: Action, date: Date = Date()) {
        self.typed = typed
        self.result = result
        self.action = action
        self.date = date
    }
}

public struct PracticeSentence: Identifiable, Hashable, Sendable {
    public enum Focus: String, CaseIterable, Sendable, Identifiable {
        case everyday = "Everyday"
        case mixups = "Mixed-up words"
        case hardWords = "Hard words"
        case quick = "Type fast"
        public var id: String { rawValue }
    }

    public let id: Int
    public let text: String
    public let focus: Focus

    public static let all: [PracticeSentence] = {
        let bank: [(Focus, [String])] = [
            (.everyday, [
                "I am going to the shop after work, do you need anything?",
                "Can you call me back when you get this message?",
                "We are running a bit late but we will be there soon.",
                "Thank you so much for the lovely present, I really like it.",
                "What time does the film start on Saturday night?",
                "My phone is nearly out of battery so I might go quiet.",
                "Please remember to bring your passport and your tickets.",
                "The kids have a day off school on Friday.",
                "Could you send me the address before we leave?",
                "I will be home by six, so let's have dinner together.",
            ]),
            (.mixups, [
                "Their dog is over there and they're taking it for a walk.",
                "Your coat is in the car and you're going to need it.",
                "It's going to rain, so the cat is hiding in its box.",
                "I would rather walk than drive, then we can talk.",
                "We were not sure where to meet, so we waited outside.",
                "I know there is no milk left, so I will buy some now.",
                "Can you hear me? I am over here by the door.",
                "The weather is so bad that I do not know whether to go.",
                "I came from the office and filled in the form.",
                "I was too tired to go to the two parties.",
            ]),
            (.hardWords, [
                "It is definitely necessary to separate the recycling.",
                "The environment in the restaurant was really pleasant.",
                "I need to explain the difference between the two systems.",
                "She has a lot of knowledge about psychology and science.",
                "We had an opportunity to visit a beautiful library.",
                "Wednesday was the most interesting day of the week.",
                "I will receive the results tomorrow, which is a relief.",
                "Her experience gives her a nuanced view of the problem.",
                "The government made an announcement about the committee.",
                "Unfortunately the vegetables were not very fresh.",
                "Please accommodate the guests in the separate building.",
                "I believe it was a coincidence and not on purpose.",
            ]),
            (.quick, [
                "The quick brown fox jumps over the lazy dog.",
                "Pack my box with five dozen big jugs of water.",
                "Just keep typing and do not worry about mistakes.",
                "Sphinx of black quartz, judge my vow.",
                "How quickly daft jumping zebras vex.",
            ]),
        ]
        var sentences: [PracticeSentence] = []
        for (focus, texts) in bank {
            for text in texts { sentences.append(PracticeSentence(id: sentences.count, text: text, focus: focus)) }
        }
        return sentences
    }()
}

/// Compares what was typed with the practice sentence, word by word.
public enum TrainingScorer {

    public enum Status: Equatable, Sendable {
        case correct
        /// A different word was typed in this place.
        case wrong(typed: String)
        /// This word was left out.
        case missing
        /// An extra word that isn't in the sentence.
        case extra(typed: String)
    }

    public struct WordResult: Equatable, Sendable, Identifiable {
        public let id: Int
        /// The word from the practice sentence (nil for an extra word).
        public let expected: String?
        public let status: Status

        public var isCorrect: Bool { status == .correct }
    }

    /// Words with surrounding punctuation removed; apostrophes are kept.
    public static func words(_ text: String) -> [String] {
        let clean = TextScanner.normalized(text)
        return TextScanner.wordRanges(in: clean).map { String(clean[$0]) }
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    /// Aligns typed words with the sentence's words (fewest edits), so one
    /// missing word doesn't make every following word look wrong.
    public static func compare(target: String, typed: String) -> [WordResult] {
        let want = words(target), got = words(typed)
        let n = want.count, m = got.count
        var cost = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { cost[i][0] = i }
        for j in 0...m { cost[0][j] = j }
        if n > 0 && m > 0 {
            for i in 1...n {
                for j in 1...m {
                    let substitute = cost[i - 1][j - 1] + (same(want[i - 1], got[j - 1]) ? 0 : 1)
                    cost[i][j] = min(substitute, cost[i - 1][j] + 1, cost[i][j - 1] + 1)
                }
            }
        }
        var results: [(String?, Status)] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i][j] == cost[i - 1][j - 1] + (same(want[i - 1], got[j - 1]) ? 0 : 1) {
                results.append((want[i - 1], same(want[i - 1], got[j - 1]) ? .correct : .wrong(typed: got[j - 1])))
                i -= 1; j -= 1
            } else if i > 0, cost[i][j] == cost[i - 1][j] + 1 {
                results.append((want[i - 1], .missing))
                i -= 1
            } else {
                results.append((nil, .extra(typed: got[j - 1])))
                j -= 1
            }
        }
        return results.reversed().enumerated().map { WordResult(id: $0.offset, expected: $0.element.0, status: $0.element.1) }
    }

    /// Share of the sentence's words typed correctly, 0…1.
    public static func accuracy(_ results: [WordResult]) -> Double {
        let expected = results.filter { $0.expected != nil }
        guard !expected.isEmpty else { return 0 }
        return Double(expected.filter(\.isCorrect).count) / Double(expected.count)
    }
}
