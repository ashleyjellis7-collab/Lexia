import Foundation

/// A weighted Damerau-Levenshtein distance whose costs reflect dyslexic
/// spelling, not just typos:
///
/// * swapped neighbours (`form`/`from`, `wiht`/`with`) are cheap,
/// * mirror/rotation letters (b/d, p/q, m/w, n/u) are cheap,
/// * vowel swaps and sound-alike consonants (c/k, s/z, f/v) are cheap,
/// * missing/extra doubled letters and vowels are cheap,
/// * spelling-by-sound rewrites (ph↔f, kn↔n, ould↔ud, ough↔uf, tion↔shun…)
///   are a single cheap step.
///
/// Inputs are lowercase ASCII byte arrays (letters and apostrophes).
public enum EditCost {

    public static let transposition = 0.5

    static let vowels: Set<UInt8> = Set("aeiou".utf8)
    static let apostrophe = UInt8(ascii: "'")

    /// 128×128 substitution-cost table.
    private static let substitutionTable: [Double] = {
        var table = [Double](repeating: 1.0, count: 128 * 128)
        func set(_ pairs: [String], _ cost: Double) {
            for pair in pairs {
                let b = Array(pair.utf8)
                let (x, y) = (Int(b[0]), Int(b[1]))
                table[x * 128 + y] = min(table[x * 128 + y], cost)
                table[y * 128 + x] = min(table[y * 128 + x], cost)
            }
        }
        // Keyboard neighbours (fat-finger slips).
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"].map { Array($0.utf8) }
        for (r1, row1) in rows.enumerated() {
            for (c1, a) in row1.enumerated() {
                for (r2, row2) in rows.enumerated() where abs(r1 - r2) <= 1 {
                    for (c2, b) in row2.enumerated() where a != b {
                        let x1 = Double(c1) + 0.5 * Double(r1)
                        let x2 = Double(c2) + 0.5 * Double(r2)
                        if abs(x1 - x2) <= 1.0 { set([String(decoding: [a, b], as: UTF8.self)], 0.55) }
                    }
                }
            }
        }
        // Sound-alike letters.
        set(["ck", "cs", "sz", "fv", "kq", "gj", "dt", "bp", "xz", "sc", "iy", "ey"], 0.6)
        // Any vowel for any other vowel.
        let v = Array("aeiou")
        for a in v { for b in v where a != b { set([String([a, b])], 0.55) } }
        // Mirror / rotation / look-alike letters.
        set(["bd", "pq", "bp", "dq", "mw", "nu", "mn", "il", "ce", "ao", "hn", "ft"], 0.45)
        for i in 0..<128 { table[i * 128 + i] = 0 }
        return table
    }()

    /// A rewrite of up to 4 bytes into up to 4 bytes, packed so the inner loop
    /// does no reference counting.
    private struct Rule {
        let from: UInt32
        let fromCount: Int
        let to: UInt32
        let toCount: Int
        let cost: Double

        init(_ from: [UInt8], _ to: [UInt8], _ cost: Double) {
            func pack(_ bytes: [UInt8]) -> UInt32 {
                bytes.enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
            }
            self.from = pack(from)
            self.fromCount = from.count
            self.to = pack(to)
            self.toCount = to.count
            self.cost = cost
        }
    }

    /// Spelling-by-sound rewrites, both directions, grouped by the last byte of
    /// `from`: the rules ending in byte `c` are `rules[ruleStart[c]..<ruleStart[c + 1]]`.
    private static let ruleTable: (rules: [Rule], start: [Int]) = {
        let raw: [(String, String, Double)] = [
            ("sten", "sen", 0.3), ("sten", "ssen", 0.3), ("ften", "fen", 0.3), ("ften", "ffen", 0.3),
            ("dne", "n", 0.35), ("one", "wun", 0.3), ("one", "un", 0.4), ("ome", "um", 0.35),
            ("are", "er", 0.4), ("are", "air", 0.3),
            ("ph", "f", 0.25), ("gh", "f", 0.4), ("kn", "n", 0.25), ("wr", "r", 0.25), ("wh", "w", 0.25),
            ("ck", "k", 0.2), ("ck", "c", 0.3), ("qu", "kw", 0.3), ("x", "ks", 0.3),
            ("tion", "shun", 0.4), ("tion", "shon", 0.4), ("tion", "shin", 0.5), ("sion", "shun", 0.4),
            ("ould", "ud", 0.35), ("ould", "ood", 0.35),
            ("ough", "uf", 0.45), ("ough", "off", 0.5), ("augh", "af", 0.4), ("augh", "aff", 0.4),
            ("ough", "ow", 0.5), ("ough", "o", 0.5), ("ough", "oo", 0.5), ("ough", "u", 0.5),
            ("ai", "e", 0.4), ("ai", "a", 0.4), ("ay", "a", 0.4), ("sch", "sk", 0.25), ("ch", "k", 0.4),
            ("oo", "u", 0.35), ("ea", "ee", 0.3), ("ee", "e", 0.3), ("ea", "e", 0.35), ("ie", "ee", 0.35),
            ("ue", "oo", 0.35), ("ew", "oo", 0.4), ("igh", "i", 0.35), ("igh", "y", 0.4), ("ight", "ite", 0.3),
            ("y", "ee", 0.4), ("le", "el", 0.3), ("er", "a", 0.45), ("or", "a", 0.5), ("our", "or", 0.3),
            ("aur", "or", 0.3), ("se", "z", 0.4), ("ce", "s", 0.35), ("s", "z", 0.5), ("ture", "cher", 0.4),
            ("dge", "j", 0.3), ("ge", "j", 0.4), ("mb", "m", 0.3), ("bt", "t", 0.3), ("tch", "ch", 0.25),
            ("ous", "us", 0.3), ("ful", "full", 0.2), ("ly", "ley", 0.3), ("ies", "ys", 0.35),
            ("ei", "ie", 0.25), ("they", "thay", 0.3),
        ]
        var byLastByte = [[Rule]](repeating: [], count: 128)
        for (a, b, cost) in raw {
            let x = Array(a.utf8), y = Array(b.utf8)
            byLastByte[Int(x.last!)].append(Rule(x, y, cost))
            byLastByte[Int(y.last!)].append(Rule(y, x, cost))
        }
        var start = [0]
        for group in byLastByte { start.append(start.last! + group.count) }
        return (byLastByte.flatMap { $0 }, start)
    }()

    private static var rules: [Rule] { ruleTable.rules }
    private static var ruleStart: [Int] { ruleTable.start }

    /// Insert/delete cost by byte, before the doubled-letter discount.
    private static let baseIndel: [Double] = {
        var table = [Double](repeating: 1.0, count: 256)
        for byte in "aeiouhwy".utf8 { table[Int(byte)] = 0.6 }
        table[Int(apostrophe)] = 0.1
        return table
    }()

    @inline(__always)
    static func substitution(_ a: UInt8, _ b: UInt8) -> Double {
        if a == b { return 0 }
        guard a < 128, b < 128 else { return 1 }
        return substitutionTable[Int(a) * 128 + Int(b)]
    }

    /// Cost of inserting or deleting `s[k]`.
    @inline(__always)
    private static func indel(_ s: UnsafeBufferPointer<UInt8>, _ k: Int, _ base: UnsafeBufferPointer<Double>) -> Double {
        let ch = s[k]
        if ch == apostrophe { return 0.1 }
        if (k > 0 && s[k - 1] == ch) || (k + 1 < s.count && s[k + 1] == ch) { return 0.3 }
        return base[Int(ch)]
    }

    @inline(__always)
    private static func hasSuffix(_ s: UnsafeBufferPointer<UInt8>, end: Int, _ packed: UInt32, _ count: Int) -> Bool {
        guard end >= count else { return false }
        let start = end - count
        for k in 0..<count where s[start + k] != UInt8(truncatingIfNeeded: packed >> (8 * UInt32(k))) {
            return false
        }
        return true
    }

    /// Weighted distance between `a` and `b`, or `.infinity` as soon as it is
    /// certain to exceed `limit`. `scratch` is reused between calls to avoid
    /// allocating a matrix per word.
    public static func distance(_ a: [UInt8], _ b: [UInt8], limit: Double = .infinity, scratch: inout [Double]) -> Double {
        let n = a.count, m = b.count
        let width = m + 1
        let size = (n + 1) * width + n + m
        if scratch.count < size { scratch = [Double](repeating: 0, count: size) }

        return a.withUnsafeBufferPointer { A in
            b.withUnsafeBufferPointer { B in
                scratch.withUnsafeMutableBufferPointer { buffer in
                    rules.withUnsafeBufferPointer { R in
                        ruleStart.withUnsafeBufferPointer { S in
                            substitutionTable.withUnsafeBufferPointer { T in
                                baseIndel.withUnsafeBufferPointer { base in
                                    kernel(A, B, buffer, R, S, T, base, limit)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func kernel(_ A: UnsafeBufferPointer<UInt8>, _ B: UnsafeBufferPointer<UInt8>,
                               _ buffer: UnsafeMutableBufferPointer<Double>,
                               _ R: UnsafeBufferPointer<Rule>, _ S: UnsafeBufferPointer<Int>,
                               _ T: UnsafeBufferPointer<Double>, _ base: UnsafeBufferPointer<Double>,
                               _ limit: Double) -> Double {
        let n = A.count, m = B.count
        let width = m + 1
        let matrix = (n + 1) * width
        // Per-letter insert/delete costs live after the matrix.
        for i in 0..<n { buffer[matrix + i] = indel(A, i, base) }
        for j in 0..<m { buffer[matrix + n + j] = indel(B, j, base) }
        if n == 0 { return (0..<m).reduce(0) { $0 + buffer[matrix + n + $1] } }
        if m == 0 { return (0..<n).reduce(0) { $0 + buffer[matrix + $1] } }

        buffer[0] = 0
        for j in 1...m { buffer[j] = buffer[j - 1] + buffer[matrix + n + j - 1] }
        for i in 1...n {
            let ai = A[i - 1]
            let row = i * width, prev = row - width
            let deleteA = buffer[matrix + i - 1]
            let rulesFrom = ai < 128 ? S[Int(ai)] : 0
            let rulesTo = ai < 128 ? S[Int(ai) + 1] : 0
            let subRow = Int(ai & 0x7F) * 128
            buffer[row] = buffer[prev] + deleteA
            var rowMin = buffer[row]
            for j in 1...m {
                let bj = B[j - 1]
                var v = buffer[prev + j] + deleteA
                let insert = buffer[row + j - 1] + buffer[matrix + n + j - 1]
                if insert < v { v = insert }
                let substitutionCost: Double = ai == bj ? 0 : (ai < 128 && bj < 128 ? T[subRow + Int(bj)] : 1)
                let substitute = buffer[prev + j - 1] + substitutionCost
                if substitute < v { v = substitute }
                if i > 1, j > 1, ai == B[j - 2], A[i - 2] == bj, ai != A[i - 2] {
                    let swap = buffer[prev - width + j - 2] + transposition
                    if swap < v { v = swap }
                }
                var r = rulesFrom
                while r < rulesTo {
                    let rule = R[r]
                    r += 1
                    guard i >= rule.fromCount, j >= rule.toCount else { continue }
                    let viaRule = buffer[(i - rule.fromCount) * width + j - rule.toCount] + rule.cost
                    if viaRule < v, hasSuffix(A, end: i, rule.from, rule.fromCount),
                       hasSuffix(B, end: j, rule.to, rule.toCount) {
                        v = viaRule
                    }
                }
                buffer[row + j] = v
                if v < rowMin { rowMin = v }
            }
            if rowMin > limit { return .infinity }
        }
        return buffer[n * width + m]
    }

    /// Convenience overload for one-off comparisons and tests.
    public static func distance(_ a: String, _ b: String) -> Double {
        var scratch: [Double] = []
        return distance(Array(a.lowercased().utf8), Array(b.lowercased().utf8), scratch: &scratch)
    }
}
