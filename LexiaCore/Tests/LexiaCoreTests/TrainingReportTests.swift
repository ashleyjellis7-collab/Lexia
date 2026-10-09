import XCTest
@testable import LexiaCore

/// Cases from real Train-tab reports. Add new ones here as reports come in.
final class TrainingReportTests: XCTestCase {

    func engine() -> SpellingEngine {
        let e = SpellingEngine(lexicon: SpellingEngineTests.lexicon)
        e.context = ContextTests.context
        return e
    }

    func centredTouches(_ word: String) -> [KeyTouch] {
        word.map { KeyTouch(letter: $0, dx: 0, dy: 0) }
    }

    // Report of 9 Oct 2026.
    func testMessyShortWordsWithClearContext() {
        let e = engine()
        XCTAssertEqual(e.analyze("tbr", previous: ContextModel.sentenceStart).autocorrect, "the")
        XCTAssertEqual(e.analyze("tjr", previous: "over").autocorrect, "the")
        XCTAssertEqual(e.analyze("dkrd", previous: "time").autocorrect, "does")
    }

    func testRealWordThatDoesNotFit() {
        XCTAssertEqual(engine().analyze("cab", previous: "we").autocorrect, "can")
    }

    func testLoneJIsI() {
        XCTAssertEqual(engine().analyze("j", previous: ContextModel.sentenceStart).autocorrect, "I")
    }

    func testMisAimedTapsDontBlockFixes() {
        // Finger landed in the middle of the wrong keys: touches must not make it worse.
        let e = engine()
        XCTAssertEqual(e.analyze("tbr", previous: ContextModel.sentenceStart, touches: centredTouches("tbr")).autocorrect, "the")
        XCTAssertEqual(e.analyze("qm", previous: "i", touches: centredTouches("qm")).autocorrect, "am")
    }

    /// Every practice sentence typed correctly must come through unchanged
    /// (words the iPhone's dictionary knows are treated as dictionary words).
    func testCorrectlyTypedPracticeSentencesAreLeftAlone() {
        let e = engine()
        var changes: [String] = []
        for sentence in PracticeSentence.all {
            var previous = ContextModel.sentenceStart
            for token in sentence.text.split(separator: " ").map(String.init) {
                let word = token.trimmingCharacters(in: .punctuationCharacters)
                guard !word.isEmpty else { continue }
                let fix = e.analyze(word, previous: previous, isDictionaryWord: true).autocorrect
                if let fix, fix.lowercased() != word.lowercased() { changes.append("\(word) → \(fix) in “\(sentence.text)”") }
                previous = token.last.map { ".!?".contains($0) } == true ? ContextModel.sentenceStart : word.lowercased()
            }
        }
        XCTAssertTrue(changes.isEmpty, changes.joined(separator: "\n"))
    }
}
