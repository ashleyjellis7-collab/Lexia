import Foundation

/// Checks for the details dyslexic writers most often get wrong and can't
/// easily spot: long numbers and codes, and weekdays that don't match the date.
public enum MessageGuard {

    // MARK: - Numbers

    /// A long number (phone, account, reference, code) at the end of the text,
    /// and how to read it aloud in chunks.
    public struct NumberReadback: Equatable, Sendable {
        public let number: String
        /// Digits spoken one by one, in groups: "0 7 7 0 0, 9 0 0, 1 2 3".
        public let spoken: String
    }

    /// The number just typed, if it has at least five digits.
    public static func trailingNumber(in text: String) -> NumberReadback? {
        var chars = Array(text)
        while let last = chars.last, last == " " || last == "." || last == "," || last == "!" || last == "?" {
            chars.removeLast()
        }
        var start = chars.count
        while start > 0, chars[start - 1].isNumber || chars[start - 1] == " " || chars[start - 1] == "-" {
            start -= 1
        }
        var number = String(chars[start...]).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
        // Don't swallow a separate number earlier in the sentence ("2 of 07700 900123").
        if let lastSpaceRun = number.range(of: "  ", options: .backwards) { number = String(number[lastSpaceRun.upperBound...]) }
        let digits = number.filter(\.isNumber)
        guard digits.count >= 5 else { return nil }

        var groups = number.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        groups = groups.flatMap { group -> [String] in
            guard group.count > 5 else { return [group] }   // keep a typed group like "07700" whole
            var chunks: [String] = []
            var rest = Substring(group)
            while rest.count > 4 {
                chunks.append(String(rest.prefix(3)))
                rest = rest.dropFirst(3)
            }
            chunks.append(String(rest))
            return chunks
        }
        let spoken = groups.map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
        return NumberReadback(number: number, spoken: spoken)
    }

    // MARK: - Dates

    /// A weekday that doesn't match the date after it ("Monday 14th" when the 14th is a Wednesday).
    public struct DateIssue: Equatable, Sendable {
        /// The end of the text, from the weekday on…
        public let original: String
        /// …and the same with the right weekday.
        public let replacement: String
        public let typedWeekday: String
        public let correctWeekday: String
        /// e.g. "Wednesday 14 October".
        public let dateDescription: String
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]
    private static let shortWeekdays: [String: Int] = [
        "mon": 2, "tue": 3, "tues": 3, "thu": 5, "thur": 5, "thurs": 5, "fri": 6,
    ]
    private static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static let pattern: NSRegularExpression = {
        let day = "(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues|tue|thurs|thur|thu|fri)"
        let month = "(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)"
        let regex = "\\b\(day)\\b,?\\s+(?:the\\s+)?(\\d{1,2})(?:st|nd|rd|th)?\\b(?:\\s+(?:of\\s+)?\(month)\\b)?"
        return try! NSRegularExpression(pattern: regex, options: [.caseInsensitive])
    }()

    /// Checks the last weekday-and-date in `text` (e.g. "Monday 14th", "Fri 3 Nov").
    /// Without a month, the next 14th from `today` is assumed.
    public static func weekdayMismatch(in text: String, today: Date = Date(),
                                       calendar: Calendar = Calendar(identifier: .gregorian)) -> DateIssue? {
        let ns = text as NSString
        guard let match = pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).last,
              let dayNumber = Int(ns.substring(with: match.range(at: 2))), (1...31).contains(dayNumber) else { return nil }
        let typed = ns.substring(with: match.range(at: 1))
        guard let typedIndex = weekdays.firstIndex(of: typed.lowercased()).map({ $0 + 1 })
                ?? shortWeekdays[typed.lowercased()] else { return nil }

        let now = calendar.dateComponents([.year, .month, .day], from: today)
        guard let thisYear = now.year, let thisMonth = now.month, let thisDay = now.day else { return nil }
        var components = DateComponents(year: thisYear, day: dayNumber)
        if match.range(at: 3).location != NSNotFound {
            let monthText = ns.substring(with: match.range(at: 3)).lowercased()
            guard let index = months.firstIndex(where: { monthText.hasPrefix($0) }) else { return nil }
            components.month = index + 1
            // A month well in the past most likely means next year.
            if index + 1 < thisMonth - 2 { components.year = thisYear + 1 }
        } else {
            components.month = dayNumber >= thisDay ? thisMonth : thisMonth + 1
        }
        guard let date = calendar.date(from: components),
              calendar.component(.day, from: date) == dayNumber else { return nil }   // e.g. 31 June
        let actualIndex = calendar.component(.weekday, from: date)
        guard actualIndex != typedIndex else { return nil }

        // Write the right weekday the way the writer did: full or short, capital or not.
        var correct = weekdays[actualIndex - 1]
        if typed.count <= 5 && weekdays.firstIndex(of: typed.lowercased()) == nil { correct = String(correct.prefix(3)) }
        if typed.first?.isUppercase == true { correct = correct.prefix(1).uppercased() + correct.dropFirst() }

        let original = ns.substring(from: match.range(at: 1).location)
        let replacement = correct + original.dropFirst(typed.count)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM"
        return DateIssue(original: original, replacement: replacement, typedWeekday: typed,
                         correctWeekday: correct, dateDescription: formatter.string(from: date))
    }
}

extension Homophones {
    /// A short, spoken explanation of a commonly mixed-up word ("their: belongs to them").
    public static func meaning(of word: String) -> String? {
        meanings[TextScanner.normalized(word).lowercased()]
    }

    private static let meanings: [String: String] = [
        "their": "belongs to them, like their house", "there": "a place, like over there",
        "they're": "they are", "your": "belongs to you, like your coat", "you're": "you are",
        "its": "belongs to it, like its tail", "it's": "it is", "to": "towards, or to do something",
        "too": "also, or too much", "two": "the number 2", "then": "next, after that",
        "than": "comparing, like bigger than", "were": "the past of are, like we were there",
        "where": "which place", "we're": "we are", "wear": "to put on clothes", "hear": "with your ears",
        "here": "this place", "know": "to be sure of something", "no": "the opposite of yes",
        "now": "at this moment", "new": "not old", "knew": "the past of know", "whose": "belonging to who",
        "who's": "who is", "of": "belonging to, like a cup of tea", "off": "not on, or away",
        "form": "a paper to fill in, or a shape", "from": "where something starts, like from home",
        "quite": "fairly, like quite good", "quiet": "not loud", "quit": "to stop",
        "lose": "to not win, or to mislay", "loose": "not tight", "affect": "to change something",
        "effect": "a result", "accept": "to say yes to", "except": "apart from",
        "weather": "rain or sun", "whether": "if", "write": "to put words down", "right": "correct, or not left",
        "buy": "to pay for", "by": "next to, or done by", "bye": "goodbye", "our": "belongs to us",
        "are": "like we are", "hour": "sixty minutes", "see": "with your eyes", "sea": "the ocean",
        "peace": "calm, no fighting", "piece": "a part of something", "brake": "to slow down",
        "break": "to smash, or a rest", "which": "what one", "witch": "a person who does magic",
        "would": "like I would like to", "wood": "from trees", "one": "the number 1", "won": "the past of win",
        "son": "a boy child", "sun": "in the sky", "meat": "food from animals", "meet": "to get together",
        "week": "seven days", "weak": "not strong", "whole": "all of it", "hole": "a gap",
        "passed": "went by, or did well in a test", "past": "time gone by", "been": "like I have been",
        "being": "like a human being", "through": "in one side and out the other", "threw": "the past of throw",
        "though": "however", "thought": "the past of think", "plain": "simple", "plane": "an aeroplane",
        "tail": "on an animal", "tale": "a story", "waist": "around your middle", "waste": "rubbish, or to use badly",
        "advice": "a suggestion, the noun", "advise": "to suggest, the verb", "led": "the past of lead",
        "lead": "to go first, or a dog lead", "bare": "uncovered", "bear": "an animal, or to carry",
        "flour": "for baking", "flower": "a plant", "desert": "a dry place", "dessert": "pudding",
        "angel": "a heavenly being", "angle": "a corner", "chose": "the past of choose", "choose": "to pick",
        "breath": "the air you breathe, the noun", "breathe": "to take a breath, the verb",
        "tired": "sleepy", "tried": "the past of try", "does": "like he does", "dose": "an amount of medicine",
    ]
}
