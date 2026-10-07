import Foundation

/// Helpers for pulling words out of the text around the cursor.
public enum TextScanner {

    public static func isWordCharacter(_ c: Character) -> Bool {
        c.isLetter || c == "'" || c == "’"
    }

    /// The word immediately before the cursor (`"I like dino"` → `"dino"`).
    public static func trailingWord(in text: String) -> String {
        var word = String(text.reversed().prefix(while: isWordCharacter).reversed())
        while let first = word.first, first == "'" || first == "’" { word.removeFirst() }
        return word
    }

    /// The word immediately after the cursor.
    public static func leadingWord(in text: String) -> String {
        String(text.prefix(while: isWordCharacter))
    }

    /// The word before the one being typed, lowercased, or `<s>` at the start
    /// of a sentence. `before` is the text before the current word.
    public static func previousWord(in before: String) -> String {
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, !".!?\n".contains(last) else { return ContextModel.sentenceStart }
        let stripped = String(trimmed.reversed().drop(while: { !isWordCharacter($0) && !".!?\n".contains($0) }).reversed())
        guard let end = stripped.last, isWordCharacter(end) else { return ContextModel.sentenceStart }
        let word = normalized(trailingWord(in: stripped)).lowercased()
        return word.isEmpty ? ContextModel.sentenceStart : word
    }

    /// Normalises curly apostrophes so `don’t` and `don't` match the lexicon.
    public static func normalized(_ word: String) -> String {
        word.replacingOccurrences(of: "’", with: "'")
    }

    /// Splits text into words, returning each word's range.
    public static func wordRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start: String.Index?
        var i = text.startIndex
        while i < text.endIndex {
            if isWordCharacter(text[i]) {
                if start == nil { start = i }
            } else if let s = start {
                ranges.append(s..<i)
                start = nil
            }
            i = text.index(after: i)
        }
        if let s = start { ranges.append(s..<text.endIndex) }
        return ranges
    }
}

/// Copies the capitalisation the writer used onto a suggestion.
public enum Casing {
    public static func apply(from typed: String, to suggestion: String) -> String {
        let letters = typed.filter(\.isLetter)
        let typedIsAllCaps = letters.count > 1 && letters.allSatisfy(\.isUppercase)
        if typedIsAllCaps { return suggestion.uppercased() }
        // The lexicon's own capitalisation wins for proper nouns and "I".
        if suggestion.contains(where: \.isUppercase) { return suggestion }
        if let first = typed.first, first.isUppercase, let s = suggestion.first {
            return s.uppercased() + suggestion.dropFirst()
        }
        return suggestion
    }
}

/// Real words that dyslexic writers commonly mix up. A spell checker can't
/// catch these (every spelling is valid), so they are resolved from context by
/// Jev.
public enum Homophones {
    public static let groups: [[String]] = [
        ["their", "there", "they're"], ["your", "you're"], ["its", "it's"], ["to", "too", "two"],
        ["then", "than"], ["were", "where", "we're", "wear"], ["of", "off"], ["form", "from"],
        ["quite", "quiet", "quit"], ["accept", "except"], ["affect", "effect"], ["lose", "loose"],
        ["weather", "whether"], ["hear", "here"], ["know", "no", "now"], ["new", "knew"],
        ["write", "right"], ["buy", "by", "bye"], ["our", "are", "hour"], ["who's", "whose"],
        ["which", "witch"], ["would", "wood"], ["see", "sea"], ["been", "being"],
        ["through", "threw", "though", "thought"], ["does", "dose"], ["saw", "was"], ["on", "no"],
        ["angel", "angle"], ["desert", "dessert"], ["brake", "break"], ["peace", "piece"],
        ["plain", "plane"], ["weak", "week"], ["whole", "hole"], ["meat", "meet"], ["one", "won"],
        ["son", "sun"], ["tail", "tale"], ["waist", "waste"], ["bored", "board"], ["allowed", "aloud"],
        ["passed", "past"], ["principal", "principle"], ["advice", "advise"], ["lead", "led"],
        ["bare", "bear"], ["flour", "flower"], ["fine", "find"], ["dab", "bad"], ["dog", "god"],
        ["sum", "some"], ["won't", "want"], ["wont", "won't"], ["chose", "choose"], ["then", "them"],
        ["though", "tough"],
        ["felt", "left"], ["pot", "top"], ["tired", "tried"], ["breath", "breathe"], ["clothes", "cloths"],
    ]

    private static let lookup: [String: [String]] = {
        var map: [String: [String]] = [:]
        for group in groups {
            for word in group {
                var existing = map[word] ?? []
                for other in group where other != word && !existing.contains(other) {
                    existing.append(other)
                }
                map[word] = existing
            }
        }
        return map
    }()

    /// Other words commonly confused with `word`, or an empty array.
    public static func alternatives(for word: String) -> [String] {
        lookup[TextScanner.normalized(word).lowercased()] ?? []
    }
}
