import Foundation

/// A frequency-ranked word list with precomputed byte forms and phonetic keys.
///
/// Entries are kept in descending frequency order so prefix completions can
/// stop at the first few matches.
public final class Lexicon: @unchecked Sendable {

    public struct Entry: Sendable {
        /// How the word should be written (`I`, `Monday`, `don't`).
        public let word: String
        /// Lowercase form, used as a lookup key.
        public let key: String
        /// Lowercase ASCII bytes used for matching.
        public let bytes: [UInt8]
        public let frequency: Int
        /// log10(frequency) scaled to 0...1 against the most frequent word.
        public let weight: Double
        public let phoneticKeys: [UInt64]
        /// One bit per letter a–z present in the word.
        public let letterMask: UInt32
    }

    /// One bit per letter a–z present in `bytes`.
    public static func letterMask(_ bytes: [UInt8]) -> UInt32 {
        var mask: UInt32 = 0
        for byte in bytes where byte >= 97 && byte <= 122 { mask |= 1 << UInt32(byte - 97) }
        return mask
    }

    public let entries: [Entry]
    private let index: [String: Int]

    public init(words: [(word: String, frequency: Int)]) {
        let sorted = words.sorted { $0.frequency > $1.frequency }
        let maxLog = log10(Double(max(sorted.first?.frequency ?? 10, 10)))
        var entries: [Entry] = []
        var index: [String: Int] = [:]
        entries.reserveCapacity(sorted.count)
        for (word, frequency) in sorted {
            let lower = word.lowercased()
            guard index[lower] == nil, !lower.isEmpty, lower.utf8.allSatisfy({ $0 < 128 }) else { continue }
            index[lower] = entries.count
            entries.append(Entry(
                word: word,
                key: lower,
                bytes: Array(lower.utf8),
                frequency: frequency,
                weight: log10(Double(max(frequency, 1))) / maxLog,
                phoneticKeys: Phonetic.keys(for: lower),
                letterMask: Self.letterMask(Array(lower.utf8))
            ))
        }
        self.entries = entries
        self.index = index
    }

    /// Parses `word<TAB>frequency` lines; `#` lines are comments.
    public convenience init(contents: String) {
        var words: [(String, Int)] = []
        contents.enumerateLines { line, _ in
            guard !line.hasPrefix("#") else { return }
            let parts = line.split(separator: "\t")
            guard parts.count == 2, let frequency = Int(parts[1]) else { return }
            words.append((String(parts[0]), frequency))
        }
        self.init(words: words.map { (word: $0.0, frequency: $0.1) })
    }

    /// The English lexicon bundled with LexiaCore (~38k words).
    public static func bundledEnglish() throws -> Lexicon {
        guard let url = Bundle.module.url(forResource: "words_en", withExtension: "txt") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return Lexicon(contents: try String(contentsOf: url, encoding: .utf8))
    }

    public func entry(for word: String) -> Entry? {
        index[word.lowercased()].map { entries[$0] }
    }

    public func contains(_ word: String) -> Bool {
        index[word.lowercased()] != nil
    }
}
