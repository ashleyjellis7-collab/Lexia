import XCTest
@testable import LexiaCore

/// Cases from the second training report.
final class SecondReportTests: XCTestCase {

    func engine(_ learning: LearningModel = LearningModel()) -> SpellingEngine {
        let e = SpellingEngine(lexicon: SpellingEngineTests.lexicon, learning: learning)
        e.context = ContextTests.context
        return e
    }

    func testALearnedFixDoesNotKeepASentenceStartCapital() {
        let learning = LearningModel()
        learning.recordCorrection(from: "th", to: "The")
        learning.recordCorrection(from: "th", to: "The")
        let e = engine(learning)
        XCTAssertEqual(e.analyze("th", previous: "between").autocorrect, "the")
        XCTAssertEqual(e.analyze("Th", previous: ContextModel.sentenceStart).autocorrect, "The")
        XCTAssertFalse(e.analyze("th", previous: "in").candidates.contains { $0.word == "The" })
    }

    func testRareDictionaryWordsNextToCommonOnesAreFixed() {
        let e = engine()
        XCTAssertEqual(e.analyze("som", previous: "buy", isDictionaryWord: true).autocorrect, "some")
        XCTAssertEqual(e.analyze("twi", previous: "the", isDictionaryWord: true).autocorrect, "two")
        // Real words Lexia knows are still left alone.
        XCTAssertNil(e.analyze("calm", previous: "you").autocorrect)
    }

    func testRunTogetherWordsAreSplit() {
        let e = engine()
        XCTAssertEqual(e.analyze("geybthis", previous: "you").autocorrect, "get this")
        XCTAssertEqual(e.analyze("inthe", previous: "was").autocorrect, "in the")
        // Ordinary misspellings are not split.
        XCTAssertEqual(e.analyze("sumthing", previous: "said").autocorrect, "something")
        XCTAssertEqual(e.analyze("becuz", previous: "late").autocorrect, "because")
    }

    func testLongWordsWithSeveralSlips() {
        let e = engine()
        XCTAssertEqual(e.analyze("affommodatw", previous: "please").autocorrect, "accommodate")
    }

    /// Prints what happens to every miss in the report, for tuning (doesn't fail).
    func testReportMisses() {
        let e = engine()
        let cases: [(String, String, String)] = [
            ("us", "there", "is"), ("but", "will", "buy"), ("som", "buy", "some"), ("calm", "you", "call"),
            ("exprrimec", "her", "experience"), ("hives", "experience", "gives"), ("diffrnc", "the", "difference"),
            ("twi", "the", "two"), ("paries", "two", "parties"), ("offic", "the", "office"),
            ("affommodatw", "please", "accommodate"), ("he", "remember", "the"), ("seperwte", "the", "separate"),
            ("buildobg", "separate", "building"), ("whryhr", "know", "whether"), ("geybthis", "you", "get this"),
        ]
        var lines: [String] = []
        for (typed, previous, wanted) in cases {
            let r = e.analyze(typed, previous: previous)
            let top = r.candidates.prefix(3).map { "\($0.word)(\(String(format: "%.2f", $0.editCost)))" }
            lines.append("\(typed) → \(r.autocorrect ?? "–") wanted \(wanted) \(r.autocorrect == wanted ? "✓" : "✗") \(top)")
        }
        print("REPORT\n" + lines.joined(separator: "\n"))
    }

    func testEndingsCloseTheSentenceFirst() {
        XCTAssertEqual(MessageEnding.edit(adding: "Thanks!", after: "Can you call me back"),
                       .init(deleteCount: 0, insert: "? Thanks!"))
        XCTAssertEqual(MessageEnding.edit(adding: "Thanks!", after: "Send it today "),
                       .init(deleteCount: 1, insert: ". Thanks!"))
        XCTAssertEqual(MessageEnding.edit(adding: "😊", after: "See you soon!"),
                       .init(deleteCount: 0, insert: " 😊"))
    }

    func testToneCheckSuggestsEndings() async throws {
        let transport = MockTransport { _ in
            (200, """
            {"model":"jev-1.13","answers":{
              "tone":{"type":"score","score":2,"confidence":0.8,"probabilities":{}},
              "unclear":{"type":"noul","noul":0.1},
              "addition":{"type":"choice","choice":"Thanks!","confidence":0.5,
                "probabilities":{"Thanks!":0.5,"No worries if not.":0.3,"(nothing)":0.1,"😊":0.05,"Made up":0.05}}
            }}
            """)
        }
        let checker = JevToneChecker(client: JevClient(configuration: JevConfiguration(apiKey: "k"), transport: transport))
        let first = try await checker.check("Send me the file")
        XCTAssertEqual(first.additions, ["Thanks!", "No worries if not."])
        // Endings already in the message aren't suggested again.
        let second = try await checker.check("Send me the file, thanks")
        XCTAssertEqual(second.additions, ["No worries if not."])
    }
}
