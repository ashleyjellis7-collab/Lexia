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
                        if abs(x1 - x2) <= 1.0 { set([String(decoding: [a, b], as: UTF8.self)], 0.75) }
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

    private struct Rule {
        let from: [UInt8]
        let to: [UInt8]
        let cost: Double
    }

    /// Spelling-by-sound rewrites, indexed by the last byte of `from`.
    private static let rules: [[Rule]] = {
        let raw: [(String, String, Double)] = [
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
        var index = [[Rule]](repeating: [], count: 128)
        for (a, b, cost) in raw {
            let x = Array(a.utf8), y = Array(b.utf8)
            index[Int(x.last!)].append(Rule(from: x, to: y, cost: cost))
            index[Int(y.last!)].append(Rule(from: y, to: x, cost: cost))
        }
        return index
    }()

    @inline(__always)
    static func substitution(_ a: UInt8, _ b: UInt8) -> Double {
        if a == b { return 0 }
        guard a < 128, b < 128 else { return 1 }
        return substitutionTable[Int(a) * 128 + Int(b)]
    }

    /// Cost of inserting or deleting `s[k]`.
    @inline(__always)
    static func indel(_ s: [UInt8], _ k: Int) -> Double {
        let ch = s[k]
        if ch == apostrophe { return 0.1 }
        if (k > 0 && s[k - 1] == ch) || (k + 1 < s.count && s[k + 1] == ch) { return 0.3 }
        if vowels.contains(ch) || ch == UInt8(ascii: "h") || ch == UInt8(ascii: "w") || ch == UInt8(ascii: "y") {
            return 0.6
        }
        return 1.0
    }

    @inline(__always)
    private static func hasSuffix(_ s: [UInt8], end: Int, _ suffix: [UInt8]) -> Bool {
        guard end >= suffix.count else { return false }
        var i = end - suffix.count
        for byte in suffix {
            if s[i] != byte { return false }
            i += 1
        }
        return true
    }

    /// Weighted distance between `a` and `b`, or `.infinity` as soon as it is
    /// certain to exceed `limit`. `scratch` is reused between calls to avoid
    /// allocating a matrix per word.
    public static func distance(_ a: [UInt8], _ b: [UInt8], limit: Double = .infinity, scratch: inout [Double]) -> Double {
        let n = a.count, m = b.count
        if n == 0 { return (0..<m).reduce(0) { $0 + indel(b, $1) } }
        if m == 0 { return (0..<n).reduce(0) { $0 + indel(a, $1) } }

        let width = m + 1
        let size = (n + 1) * width
        if scratch.count < size { scratch = [Double](repeating: 0, count: size) }

        scratch[0] = 0
        for j in 1...m { scratch[j] = scratch[j - 1] + indel(b, j - 1) }
        for i in 1...n {
            let ai = a[i - 1]
            let rowRules = ai < 128 ? rules[Int(ai)] : []
            let deleteA = indel(a, i - 1)
            scratch[i * width] = scratch[(i - 1) * width] + deleteA
            var rowMin = scratch[i * width]
            for j in 1...m {
                let bj = b[j - 1]
                var v = min(
                    scratch[(i - 1) * width + j] + deleteA,
                    scratch[i * width + j - 1] + indel(b, j - 1),
                    scratch[(i - 1) * width + j - 1] + substitution(ai, bj)
                )
                if i > 1, j > 1, ai == b[j - 2], a[i - 2] == bj, ai != a[i - 2] {
                    v = min(v, scratch[(i - 2) * width + j - 2] + transposition)
                }
                for rule in rowRules where i >= rule.from.count && j >= rule.to.count {
                    if hasSuffix(a, end: i, rule.from), hasSuffix(b, end: j, rule.to) {
                        v = min(v, scratch[(i - rule.from.count) * width + (j - rule.to.count)] + rule.cost)
                    }
                }
                scratch[i * width + j] = v
                rowMin = min(rowMin, v)
            }
            if rowMin > limit { return .infinity }
        }
        return scratch[n * width + m]
    }

    /// Convenience overload for one-off comparisons and tests.
    public static func distance(_ a: String, _ b: String) -> Double {
        var scratch: [Double] = []
        return distance(Array(a.lowercased().utf8), Array(b.lowercased().utf8), scratch: &scratch)
    }
}
