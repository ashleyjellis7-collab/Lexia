import Foundation

/// A deliberately loose "sounds like" code, tuned for the way dyslexic writers
/// often spell: by sound. `because`, `becuz` and `becaus` all share a code, as
/// do `phone`/`fone`, `knife`/`nife` and `enough`/`enuf`.
///
/// Vowels after the first letter are dropped entirely (dyslexic vowel choice is
/// very unreliable), silent letters are removed and common digraphs collapse to
/// a single sound. Words with an ambiguous `gh` get two codes ("enough" → f,
/// "though" → silent).
public enum Phonetic {

    /// Phonetic codes for a word (one or two of them).
    public static func codes(for word: String) -> [String] {
        var w = String(String.UnicodeScalarView(
            word.lowercased().unicodeScalars.filter { ("a"..."z").contains($0) }
        ))
        guard !w.isEmpty else { return [""] }

        for (silent, sound) in [("kn", "n"), ("gn", "n"), ("wr", "r"), ("ps", "s"), ("wh", "w")]
        where w.hasPrefix(silent) {
            w = sound + w.dropFirst(silent.count)
        }
        if w.hasPrefix("x") { w = "s" + w.dropFirst() }
        if w.hasSuffix("mb") { w.removeLast() }

        let replacements: [(String, String)] = [
            // Silent letters: listen, often, Wednesday; "one" sounds like "wun".
            ("sten", "sen"), ("ften", "fen"), ("dnes", "ns"), ("one", "wun"),
            ("ould", "ud"), ("sch", "sk"),
            // "sh" sounds: conscience, special, initial, delicious.
            ("scie", "Xe"), ("scio", "Xo"), ("cia", "Xa"), ("cie", "Xe"), ("cio", "Xo"), ("tia", "Xa"), ("tiou", "Xou"),
            ("tch", "ch"), ("dge", "j"), ("tion", "shn"), ("sion", "shn"),
            ("cious", "shs"), ("ph", "f"), ("ck", "k"), ("sh", "X"), ("ch", "X"), ("th", "0"),
            ("qu", "kw"), ("q", "k"), ("x", "ks"), ("z", "s"),
        ]
        for (from, to) in replacements {
            w = w.replacingOccurrences(of: from, with: to)
        }

        let variants = w.contains("gh")
            ? [w.replacingOccurrences(of: "gh", with: "f"), w.replacingOccurrences(of: "gh", with: "")]
            : [w]

        var result: [String] = []
        for variant in variants {
            let chars = Array(variant)
            var out: [Character] = []
            for (i, raw) in chars.enumerated() {
                var c = raw
                let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
                if c == "c" {
                    c = (next.map { "eiy".contains($0) } ?? false) ? "s" : "k"
                } else if c == "g", let next, "eiy".contains(next) {
                    c = "j"
                }
                if "aeiouy".contains(c) {
                    if i == 0 { out.append("A") }
                    continue
                }
                if i > 0, c == "h" || c == "w" { continue }
                if c == "d" { c = "t" }   // "nuanst" sounds like "nuanced"
                if out.last == c { continue }
                out.append(c)
            }
            let code = String(out)
            if !result.contains(code) { result.append(code) }
        }
        return result
    }

    /// Stable 64-bit hashes of `codes(for:)`, for compact storage in the lexicon.
    public static func keys(for word: String) -> [UInt64] {
        codes(for: word).map(fnv1a)
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
