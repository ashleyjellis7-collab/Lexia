import XCTest
@testable import LexiaCore

final class LearningTests: XCTestCase {

    func engine(_ learning: LearningModel = LearningModel()) -> SpellingEngine {
        SpellingEngine(lexicon: SpellingEngineTests.lexicon, learning: learning)
    }

    /// Typos from a real message typed on Lexia.
    func testTyposFromARealMessageAreAutocorrected() {
        let e = engine()
        for (typed, expected) in ["tje": "the", "exampl": "example", "accurat": "accurate", "abov": "above",
                                  "wjat": "what", "jusr": "just", "aboit": "about", "coukd": "could"] {
            XCTAssertEqual(e.analyze(typed).autocorrect, expected, typed)
        }
    }

    func testAPickedFixIsUsedAutomaticallyNextTime() {
        let learning = LearningModel()
        let e = engine(learning)
        XCTAssertNotEqual(e.analyze("shpuke").autocorrect, "should")
        learning.recordCorrection(from: "shpuke", to: "should")
        XCTAssertEqual(e.analyze("shpuke").autocorrect, "should")
        XCTAssertEqual(e.analyze("shpuke").candidates.first?.word, "should")
    }

    func testRealWordFixesNeedToBePickedTwice() {
        let learning = LearningModel()
        let e = engine(learning)
        XCTAssertNil(e.analyze("luke").autocorrect)
        learning.recordCorrection(from: "luke", to: "like")
        XCTAssertNil(e.analyze("luke").autocorrect, "one pick could be a slip")
        XCTAssertEqual(e.analyze("luke").candidates.first?.word, "like")
        learning.recordCorrection(from: "luke", to: "like")
        XCTAssertEqual(e.analyze("Luke").autocorrect, "Like")
    }

    func testUndoingACorrectionStopsIt() {
        let learning = LearningModel()
        let e = engine(learning)
        XCTAssertEqual(e.analyze("tje").autocorrect, "the")
        learning.recordCorrection(from: "tje", to: "the")   // autocorrect applied…
        learning.recordRejection(from: "tje", to: "the")    // …then undone
        XCTAssertNil(e.analyze("tje").autocorrect)
    }

    func testFrequentlyUsedWordsRankHigher() {
        let learning = LearningModel()
        let e = engine(learning)
        let before = e.analyze("thier").candidates.map(\.word)
        XCTAssertEqual(before.first, "their")
        for _ in 0..<40 { learning.recordUse("there") }
        XCTAssertEqual(e.analyze("thier").candidates.first?.word, "there")
    }

    func testLearningSurvivesSaveAndLoad() {
        let learning = LearningModel()
        learning.recordCorrection(from: "shpuke", to: "should")
        learning.recordUse("dinosaur")
        let restored = LearningModel(data: learning.save())
        XCTAssertEqual(restored.learnedFix(for: "shpuke")?.word, "should")
        XCTAssertGreaterThan(restored.usageBoost("dinosaur"), 0)
        restored.load(nil)
        XCTAssertNil(restored.learnedFix(for: "shpuke"))
    }
}
