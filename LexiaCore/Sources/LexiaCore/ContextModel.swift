import Foundation

/// How often each word follows another ("I am", "going to", "the dog"), from
/// the Google Books Ngram fiction corpus. This is what lets Lexia choose
/// "am" over "pm" in "I qm going", and predict the next word.
///
/// File format (`bigrams_en.bin`, little-endian):
/// `"LXB1"`, UInt32 vocabulary byte length, newline-separated vocabulary,
/// UInt32 pair count, then (UInt32 previous, UInt32 next, UInt32 count)
/// triples sorted by (previous, next). Index 0 is `<s>`, the start of a sentence.
public final class ContextModel: @unchecked Sendable {

    public static let sentenceStart = "<s>"

    private let vocabulary: [String]
    private let index: [String: UInt32]
    /// (previous << 32 | next), sorted.
    private let keys: [UInt64]
    private let counts: [UInt32]
    /// Total count of pairs starting with each word.
    private let followTotals: [Double]
    /// Total count of pairs ending with each word (a unigram estimate).
    private let wordTotals: [Double]
    /// Smallest pair count kept for each first word: an upper bound for pairs that were trimmed.
    private let minimumKept: [Double]
    private let grandTotal: Double

    public enum LoadError: Error { case badFormat }

    public init(data: Data) throws {
        var vocabulary: [String] = []
        var keys: [UInt64] = []
        var counts: [UInt32] = []
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var offset = 0
            func u32() throws -> UInt32 {
                guard offset + 4 <= raw.count else { throw LoadError.badFormat }
                let value = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
                offset += 4
                return value
            }
            guard raw.count >= 8, String(decoding: raw[0..<4], as: UTF8.self) == "LXB1" else { throw LoadError.badFormat }
            offset = 4
            let vocabBytes = Int(try u32())
            guard offset + vocabBytes <= raw.count else { throw LoadError.badFormat }
            vocabulary = String(decoding: raw[offset..<offset + vocabBytes], as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            offset += vocabBytes
            let pairs = Int(try u32())
            guard offset + pairs * 12 <= raw.count else { throw LoadError.badFormat }
            keys.reserveCapacity(pairs)
            counts.reserveCapacity(pairs)
            for _ in 0..<pairs {
                let previous = UInt64(try u32()), next = UInt64(try u32())
                keys.append(previous << 32 | next)
                counts.append(try u32())
            }
        }

        var follow = [Double](repeating: 0, count: vocabulary.count)
        var words = [Double](repeating: 0, count: vocabulary.count)
        var minimum = [Double](repeating: .infinity, count: vocabulary.count)
        for (key, count) in zip(keys, counts) {
            let previous = Int(key >> 32), next = Int(key & 0xFFFF_FFFF)
            guard previous < vocabulary.count, next < vocabulary.count else { throw LoadError.badFormat }
            follow[previous] += Double(count)
            words[next] += Double(count)
            minimum[previous] = min(minimum[previous], Double(count))
        }
        var index: [String: UInt32] = [:]
        for (i, word) in vocabulary.enumerated() { index[word] = UInt32(i) }

        self.vocabulary = vocabulary
        self.index = index
        self.keys = keys
        self.counts = counts
        self.followTotals = follow
        self.wordTotals = words
        self.minimumKept = minimum
        self.grandTotal = max(words.reduce(0, +), 1)
    }

    public static func bundledEnglish() throws -> ContextModel {
        guard let url = Bundle.module.url(forResource: "bigrams_en", withExtension: "bin") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try ContextModel(data: Data(contentsOf: url, options: .mappedIfSafe))
    }

    private func id(_ word: String) -> UInt32? {
        index[TextScanner.normalized(word).lowercased()]
    }

    private func count(_ previous: UInt32, _ next: UInt32) -> UInt32 {
        let key = UInt64(previous) << 32 | UInt64(next)
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < key { low = mid + 1 } else { high = mid }
        }
        return low < keys.count && keys[low] == key ? counts[low] : 0
    }

    /// How much more likely `word` is after `previous` than in general, as
    /// log10(P(word | previous) / P(word)). nil when there's nothing to go on.
    public func contextLift(of word: String, after previous: String) -> Double? {
        guard let p = id(previous), followTotals[Int(p)] >= 50, let w = id(word) else { return nil }
        let overall = (wordTotals[Int(w)] + 1) / grandTotal
        let pairCount = count(p, w)
        guard pairCount > 0 else {
            // The pair was trimmed, so it's rarer than the rarest pair kept for `previous`.
            // That only counts against `word` if even that upper bound is below average ("he us").
            return min(0, log10((minimumKept[Int(p)] / followTotals[Int(p)]) / overall))
        }
        return log10((Double(pairCount) / followTotals[Int(p)]) / overall)
    }

    /// The words most likely to come next after `previous` (`<s>` for a new sentence).
    public func predictions(after previous: String, limit: Int = 3) -> [String] {
        guard let p = id(previous) else { return [] }
        let start = UInt64(p) << 32
        var low = 0, high = keys.count
        while low < high {
            let mid = (low + high) / 2
            if keys[mid] < start { low = mid + 1 } else { high = mid }
        }
        var best: [(word: Int, count: UInt32)] = []
        var i = low
        while i < keys.count, keys[i] >> 32 == UInt64(p) {
            let c = counts[i]
            if best.count < limit || c > best[best.count - 1].count {
                best.append((Int(keys[i] & 0xFFFF_FFFF), c))
                best.sort { $0.count > $1.count }
                if best.count > limit { best.removeLast() }
            }
            i += 1
        }
        return best.map { vocabulary[$0.word] }
    }
}
