import XCTest
@testable import LexiaCore

final class ContextTests: XCTestCase {

    static let context: ContextModel = try! ContextModel.bundledEnglish()

    func engine() -> SpellingEngine {
        let e = SpellingEngine(lexicon: SpellingEngineTests.lexicon)
        e.context = Self.context
        return e
    }

    /// Replays text word by word, like the keyboard: each word is checked
    /// with the (possibly corrected) word before it.
    func replay(_ text: String, dictionary: Set<String> = []) -> String {
        let e = engine()
        var previous = ContextModel.sentenceStart
        var out: [String] = []
        for token in text.split(separator: " ").map(String.init) {
            let word = token.trimmingCharacters(in: .punctuationCharacters)
            let result = e.analyze(word, previous: previous, isDictionaryWord: dictionary.contains(word.lowercased()))
            let final = result.autocorrect ?? word
            out.append(token.replacingOccurrences(of: word, with: final))
            previous = ".!?".contains(token.last!) ? ContextModel.sentenceStart : final.lowercased()
        }
        return out.joined(separator: " ")
    }

    func testTheStoryFromTesting() {
        let got = replay("I qm going ti write a story and see what comes up. I know a dog calles belu",
                         dictionary: ["belu"])
        XCTAssertEqual(got, "I am going to write a story and see what comes up. I know a dog called belu")
    }

    func testOtherTyposFromTesting() {
        XCTAssertEqual(replay("for exampl in this message"), "for example in this message")
        XCTAssertEqual(replay("less accurat than"), "less accurate than")
    }

    func testCorrectTextIsLeftAlone() {
        for sentence in [
            "I am going to write a story and see what comes up.",
            "We went to the park on Saturday and played football until it got dark.",
            "Can you send me the form before Friday? I need to fill it in and post it back.",
            "My sister said she would come over later but she is not sure what time she will be free.",
            "The weather was cold so I wore my new coat and a hat.",
            "He woofs and walks every day.",
        ] {
            XCTAssertEqual(replay(sentence, dictionary: ["woofs"]), sentence)
        }
    }

    func testDictionaryWordsAreNeverCorrected() {
        let e = engine()
        XCTAssertNil(e.analyze("woofs", previous: "he", isDictionaryWord: true).autocorrect)
        XCTAssertNil(e.analyze("typos", previous: "the", isDictionaryWord: true).autocorrect)
    }

    func testContextPicksBetweenSimilarWords() {
        let e = engine()
        XCTAssertEqual(e.analyze("qm", previous: "i").autocorrect, "am")
        XCTAssertEqual(e.analyze("us", previous: "he").candidates.first?.word, "is")
    }

    func testNextWordPredictions() {
        XCTAssertTrue(Self.context.predictions(after: "going", limit: 3).contains("to"))
        XCTAssertFalse(Self.context.predictions(after: ContextModel.sentenceStart, limit: 3).isEmpty)
        let p = SuggestionPipeline(engine: engine())
        let chips = p.predictions(for: TypingContext(before: "I am going ", word: ""))
        XCTAssertEqual(chips.first?.kind, .prediction)
        XCTAssertTrue(chips.map(\.text).contains("to"))
        // Capitalised at the start of a sentence.
        let start = p.predictions(for: TypingContext(before: "", word: ""))
        XCTAssertTrue(start.allSatisfy { $0.text.first?.isUppercase == true })
    }

    func testPreviousWord() {
        XCTAssertEqual(TextScanner.previousWord(in: "I am going "), "going")
        XCTAssertEqual(TextScanner.previousWord(in: "Hello, "), "hello")
        XCTAssertEqual(TextScanner.previousWord(in: "The end. "), ContextModel.sentenceStart)
        XCTAssertEqual(TextScanner.previousWord(in: ""), ContextModel.sentenceStart)
    }

    func testModelLoadsQuickly() {
        measure { _ = try? ContextModel.bundledEnglish() }
    }
}

final class LookBackTests: XCTestCase {

    func pipeline() -> SuggestionPipeline {
        let engine = SpellingEngine(lexicon: SpellingEngineTests.lexicon)
        engine.context = ContextTests.context
        return SuggestionPipeline(engine: engine)
    }

    func testMixedUpWordsAreFixedOnceTheNextWordArrives() {
        let p = pipeline()
        XCTAssertEqual(p.localLookBackFix(textBefore: "and lived their until ")?.replacement, "there until ")
        XCTAssertEqual(p.localLookBackFix(textBefore: "they lost there way ")?.replacement, "their way ")
        XCTAssertEqual(p.localLookBackFix(textBefore: "I no that ")?.replacement, "know that ")
        XCTAssertEqual(p.localLookBackFix(textBefore: "it is better then me ")?.replacement, "than me ")
        XCTAssertEqual(p.localLookBackFix(textBefore: "I came form the ")?.replacement, "from the ")
    }

    func testCorrectHomophonesAreLeftAlone() {
        let p = pipeline()
        for text in ["they took all their friends ", "it is over there and ", "I want to go ", "is your car ",
                     "the dog lost its bone ", "I know that ", "we went there ", "from the shop "] {
            XCTAssertNil(p.localLookBackFix(textBefore: text), text)
        }
    }

    func testNothingAcrossPunctuation() {
        XCTAssertNil(pipeline().localLookBackFix(textBefore: "lived their. Until "))
    }

    func testSpaceInsteadOfALetter() {
        let p = pipeline()
        XCTAssertEqual(p.spaceSlipFix(before: "now a ", word: "d")?.replacement, "and")
        XCTAssertNil(p.spaceSlipFix(before: "I have a ", word: "dog"))
        XCTAssertNil(p.spaceSlipFix(before: "plan a ", word: "is"))
    }

    func testNamesDontBeatWordsTypedInLowercase() {
        let e = SpellingEngine(lexicon: SpellingEngineTests.lexicon)
        XCTAssertEqual(e.analyze("roghgs").candidates.first?.word, "rights")
    }
}
