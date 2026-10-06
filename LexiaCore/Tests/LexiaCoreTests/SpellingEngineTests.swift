import XCTest
@testable import LexiaCore

final class SpellingEngineTests: XCTestCase {

    static let lexicon: Lexicon = try! Lexicon.bundledEnglish()
    var engine: SpellingEngine!

    override func setUp() {
        engine = SpellingEngine(lexicon: Self.lexicon)
    }

    func testBundledLexiconLoads() {
        XCTAssertGreaterThan(Self.lexicon.entries.count, 30_000)
        XCTAssertTrue(Self.lexicon.contains("because"))
        XCTAssertEqual(Self.lexicon.entry(for: "i")?.word, "I")
    }

    /// Spellings typical of dyslexic writers: phonetic, reversed, transposed, dropped letters.
    func testDyslexicMisspellingsRankTheIntendedWordFirst() {
        let cases: [String: String] = [
            "becuz": "because", "becaus": "because", "fone": "phone", "teh": "the", "freind": "friend",
            "wiht": "with", "sed": "said", "enuf": "enough", "nife": "knife", "rong": "wrong",
            "beleive": "believe", "neccesary": "necessary", "dady": "daddy", "hapy": "happy",
            "pepole": "people", "peple": "people", "thay": "they", "wud": "would", "cud": "could",
            "shud": "should", "frist": "first", "qen": "pen", "litle": "little", "dinosor": "dinosaur",
            "skool": "school", "laff": "laugh", "giv": "give", "bak": "back", "definately": "definitely",
            "diffrent": "different", "tomorow": "tomorrow", "realy": "really", "wierd": "weird",
            "thier": "their", "sumthing": "something", "agen": "again", "wotch": "watch", "ther": "there",
        ]
        var failures: [String] = []
        for (typed, expected) in cases.sorted(by: { $0.key < $1.key }) {
            let top = engine.analyze(typed).candidates.first?.word
            if top != expected { failures.append("\(typed) → \(top ?? "nil") (wanted \(expected))") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    func testConfidentCorrectionsAutocorrect() {
        XCTAssertEqual(engine.analyze("becuz").autocorrect, "because")
        XCTAssertEqual(engine.analyze("teh").autocorrect, "the")
        XCTAssertEqual(engine.analyze("dont").autocorrect, "don't")
        XCTAssertEqual(engine.analyze("im").autocorrect, "I'm")
        XCTAssertEqual(engine.analyze("i").autocorrect, "I")
    }

    func testRealWordsAreNeverAutocorrectedOnDevice() {
        for word in ["dog", "form", "their", "sum", "dab", "was"] {
            XCTAssertNil(engine.analyze(word).autocorrect, word)
            XCTAssertTrue(engine.analyze(word).isKnownWord, word)
        }
    }

    func testCasingFollowsTheWriter() {
        XCTAssertEqual(engine.analyze("Becuz").autocorrect, "Because")
        XCTAssertEqual(engine.analyze("BECUZ").autocorrect, "BECAUSE")
        XCTAssertEqual(engine.analyze("Dont").autocorrect, "Don't")
    }

    func testPersonalWordsAreRespected() {
        XCTAssertNotNil(engine.analyze("becuz").autocorrect)
        engine.learn(["Becuz"])
        XCTAssertNil(engine.analyze("becuz").autocorrect)
        XCTAssertTrue(engine.analyze("becuz").isKnownWord)
    }

    func testCompletions() {
        XCTAssertTrue(engine.analyze("beca").completions.contains("because"))
    }

    func testNonEnglishLettersAreLeftAlone() {
        let result = engine.analyze("café")
        XCTAssertNil(result.autocorrect)
        XCTAssertTrue(result.candidates.isEmpty)
    }

    func testAnalysisIsFastEnoughForTyping() {
        measure {
            _ = engine.analyze("dinosor")
        }
    }
}

final class PhoneticAndCostTests: XCTestCase {

    func testSoundAlikeSpellingsShareACode() {
        let pairs = [("because", "becuz"), ("phone", "fone"), ("knife", "nife"), ("enough", "enuf"),
                     ("wrong", "rong"), ("said", "sed"), ("school", "skool")]
        for (word, spelling) in pairs {
            XCTAssertFalse(Set(Phonetic.codes(for: word)).isDisjoint(with: Phonetic.codes(for: spelling)),
                           "\(word) / \(spelling): \(Phonetic.codes(for: word)) vs \(Phonetic.codes(for: spelling))")
        }
    }

    func testDyslexicSlipsCostLessThanArbitraryTypos() {
        XCTAssertLessThan(EditCost.distance("dab", "bab"), EditCost.distance("dab", "kab"))  // b/d mirror
        XCTAssertLessThan(EditCost.distance("from", "form"), EditCost.distance("from", "frxm")) // swap
        XCTAssertLessThan(EditCost.distance("fone", "phone"), 0.5)                            // ph ↔ f
        XCTAssertLessThan(EditCost.distance("litle", "little"), 0.5)                          // dropped double
        XCTAssertEqual(EditCost.distance("same", "same"), 0)
    }

    func testTextScanning() {
        XCTAssertEqual(TextScanner.trailingWord(in: "I like dino"), "dino")
        XCTAssertEqual(TextScanner.trailingWord(in: "I don’t"), "don’t")
        XCTAssertEqual(TextScanner.trailingWord(in: "said 'hel"), "hel")
        XCTAssertEqual(TextScanner.trailingWord(in: "end. "), "")
        XCTAssertEqual(TextScanner.wordRanges(in: "their going!").count, 2)
    }
}
