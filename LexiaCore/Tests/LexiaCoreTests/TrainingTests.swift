import XCTest
@testable import LexiaCore

final class TrainingTests: XCTestCase {

    func testPerfectTyping() {
        let r = TrainingScorer.compare(target: "I am going to the shop.", typed: "i am going to the shop")
        XCTAssertTrue(r.allSatisfy(\.isCorrect))
        XCTAssertEqual(TrainingScorer.accuracy(r), 1)
    }

    func testWrongWordsAreFound() {
        let r = TrainingScorer.compare(target: "It is definitely necessary", typed: "It is definatly nesesary")
        XCTAssertEqual(r.map(\.status), [.correct, .correct, .wrong(typed: "definatly"), .wrong(typed: "nesesary")])
        XCTAssertEqual(TrainingScorer.accuracy(r), 0.5)
    }

    func testAMissingWordDoesNotShiftEverything() {
        let r = TrainingScorer.compare(target: "we will be there soon", typed: "we be there soon")
        XCTAssertEqual(r.map(\.status), [.correct, .missing, .correct, .correct, .correct])
    }

    func testExtraWordsAndApostrophes() {
        let r = TrainingScorer.compare(target: "they're here", typed: "they’re over here")
        XCTAssertEqual(r.map(\.status), [.correct, .extra(typed: "over"), .correct])
        XCTAssertEqual(TrainingScorer.accuracy(r), 1)
    }

    func testSentenceBank() {
        XCTAssertGreaterThan(PracticeSentence.all.count, 30)
        for focus in PracticeSentence.Focus.allCases {
            XCTAssertFalse(PracticeSentence.all.filter { $0.focus == focus }.isEmpty)
        }
    }

    func testEventsRoundTrip() throws {
        let event = TrainingEvent(typed: "nesesary", result: "necessary", action: .autocorrected)
        let data = try JSONEncoder().encode([event])
        XCTAssertEqual(try JSONDecoder().decode([TrainingEvent].self, from: data), [event])
    }
}
