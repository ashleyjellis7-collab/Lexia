import XCTest
@testable import LexiaCore

final class MessageGuardTests: XCTestCase {

    var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        return c
    }()

    /// Friday 9 October 2026.
    var today: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 12))! }

    func issue(_ text: String) -> MessageGuard.DateIssue? {
        MessageGuard.weekdayMismatch(in: text, today: today, calendar: calendar)
    }

    func testAWrongWeekdayIsSpotted() throws {
        let found = try XCTUnwrap(issue("Can we meet on Monday 14th"))
        XCTAssertEqual(found.correctWeekday, "Wednesday")
        XCTAssertEqual(found.original, "Monday 14th")
        XCTAssertEqual(found.replacement, "Wednesday 14th")
        XCTAssertEqual(found.dateDescription, "Wednesday 14 October")
    }

    func testTheWritersStyleIsKept() throws {
        XCTAssertEqual(try XCTUnwrap(issue("see you mon 14th")).replacement, "wed 14th")
    }

    func testMatchingDatesAreLeftAlone() {
        XCTAssertNil(issue("Can we meet on Wednesday 14th"))
        XCTAssertNil(issue("Monday 12 October works"))
        XCTAssertNil(issue("Tuesday the 3rd of November"))
        XCTAssertNil(issue("no dates here"))
    }

    func testAnEarlierDayMeansNextMonth() throws {
        // The 2nd, seen on 9 October, is 2 November 2026 – a Monday.
        XCTAssertNil(issue("Monday 2nd"))
        XCTAssertEqual(try XCTUnwrap(issue("Friday 2nd")).correctWeekday, "Monday")
    }

    func testLongNumbersAreReadInChunks() throws {
        let number = try XCTUnwrap(MessageGuard.trailingNumber(in: "call me on 07700 900123"))
        XCTAssertEqual(number.spoken, "0 7 7 0 0, 9 0 0, 1 2 3")
        XCTAssertEqual(MessageGuard.trailingNumber(in: "ref 12345678 ")?.spoken, "1 2 3, 4 5 6, 7 8")
        XCTAssertNil(MessageGuard.trailingNumber(in: "I have 1234"))
        XCTAssertNil(MessageGuard.trailingNumber(in: "hello there"))
    }

    func testHomophonesAreExplained() {
        XCTAssertEqual(Homophones.meaning(of: "they're"), "they are")
        XCTAssertEqual(Homophones.meaning(of: "Their"), "belongs to them, like their house")
        XCTAssertNil(Homophones.meaning(of: "dinosaur"))
    }
}

final class JevToneCheckerTests: XCTestCase {

    func testToneIsJudgedNotRewritten() async throws {
        let transport = MockTransport { _ in
            (200, """
            {"model":"jev-1.13","answers":{
              "tone":{"type":"score","score":2.2,"confidence":0.8,"legend":{"0":"a","1":"b","2":"c","3":"d"},"probabilities":{"0":0.05,"1":0.1,"2":0.6,"3":0.25}},
              "unclear":{"type":"noul","noul":0.7}
            }}
            """)
        }
        let checker = JevToneChecker(client: JevClient(configuration: JevConfiguration(apiKey: "k"), transport: transport))
        let verdict = try await checker.check("Do it now.")
        XCTAssertEqual(verdict.level, 2)
        XCTAssertEqual(verdict.summary, "Could sound a bit abrupt · might be unclear")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: transport.requests[0].httpBody!) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        XCTAssertEqual((questions["tone"] as? [String: Any])?["type"] as? String, "score")
        XCTAssertEqual((body["state"] as? [String: Any])?["message"] as? String, "Do it now.")
    }
}
