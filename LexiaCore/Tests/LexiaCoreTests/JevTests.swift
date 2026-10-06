import XCTest
@testable import LexiaCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Replays canned System One responses and records what was sent.
final class MockTransport: JevTransport, @unchecked Sendable {
    var responder: (_ body: [String: Any]) -> (Int, String)
    private(set) var requests: [URLRequest] = []

    init(responder: @escaping (_ body: [String: Any]) -> (Int, String)) {
        self.responder = responder
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let (status, json) = responder(body)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(json.utf8), response)
    }

    /// A response picking `choice` with `confidence`, and `typedIsIntended` for the noul.
    static func answering(_ choice: String, confidence: Double, typedIsIntended: Double) -> MockTransport {
        MockTransport { body in
            let questions = body["questions"] as? [String: Any] ?? [:]
            let intended = questions["intended_word"] as? [String: Any] ?? [:]
            let options = (intended["criteria"] as? [String: Any] ?? [:]).keys
            let rest = (1 - confidence) / Double(max(options.count - 1, 1))
            let probabilities = options.map { "\"\($0)\": \($0 == choice ? confidence : rest)" }.joined(separator: ",")
            return (200, """
            {"model":"jev-1.13","answers":{
              "intended_word":{"type":"choice","choice":"\(choice)","confidence":\(confidence),"probabilities":{\(probabilities)}},
              "typed_is_intended":{"type":"noul","noul":\(typedIsIntended)}
            },"usage":{"input_tokens":120,"output_tokens":0}}
            """)
        }
    }
}

final class JevClientTests: XCTestCase {

    func testRequestMatchesTheSystemOneWireFormat() async throws {
        let transport = MockTransport.answering("because", confidence: 0.9, typedIsIntended: 0.05)
        let reranker = JevReranker(client: JevClient(configuration: JevConfiguration(apiKey: "test-key"), transport: transport))
        _ = try await reranker.decide(context: TypingContext(before: "I was late ", word: "becuz"),
                                      options: ["becuz", "because", "bucks"])

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let state = try XCTUnwrap(body["state"] as? [String: Any])
        XCTAssertEqual(state["typed_word"] as? String, "becuz")
        XCTAssertEqual(state["text_before"] as? String, "I was late ")

        let questions = try XCTUnwrap(body["questions"] as? [String: Any])
        let choice = try XCTUnwrap(questions["intended_word"] as? [String: Any])
        XCTAssertEqual(choice["type"] as? String, "choice")
        let criteria = try XCTUnwrap(choice["criteria"] as? [String: Any])
        XCTAssertEqual(Set(criteria.keys), ["becuz", "because", "bucks"])
        XCTAssertTrue(criteria["because"] is NSNull, "undescribed options must be sent as null, not dropped")
        let noul = try XCTUnwrap(questions["typed_is_intended"] as? [String: Any])
        XCTAssertEqual(noul["type"] as? String, "noul")
    }

    func testDecodesAllAnswerTypes() throws {
        let json = """
        {"model":"jev-1.13","answers":{
          "a":{"type":"noul","noul":0.98},
          "b":{"type":"choice","choice":"billing","confidence":0.91,"probabilities":{"billing":0.91,"other":0.09}},
          "c":{"type":"score","score":1.4,"confidence":0.7,"legend":{"0":"Calm","1":"Upset","2":"Angry"},"probabilities":{"0":0.1,"1":0.4,"2":0.5}}
        },"usage":{"input_tokens":10,"output_tokens":0}}
        """
        let response = try JSONDecoder().decode(SystemOneResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.answers["a"], .noul(probability: 0.98))
        XCTAssertEqual(response.answers["b"], .choice(label: "billing", confidence: 0.91, probabilities: ["billing": 0.91, "other": 0.09]))
        guard case let .score(value, _, probabilities)? = response.answers["c"] else { return XCTFail() }
        XCTAssertEqual(value, 1.4)
        XCTAssertEqual(probabilities["2"], 0.5)
    }

    func testHTTPErrorsSurface() async {
        let transport = MockTransport { _ in (401, #"{"error":"invalid api key"}"#) }
        let client = JevClient(configuration: JevConfiguration(apiKey: "bad"), transport: transport)
        do {
            _ = try await client.systemOne(state: .string("x"), questions: ["q": .noul(instructions: "?")])
            XCTFail("expected an error")
        } catch let error as JevError {
            guard case .http(401, _) = error else { return XCTFail("\(error)") }
        } catch {
            XCTFail("\(error)")
        }
    }

    func testMissingKeyFailsBeforeAnyRequest() async {
        let transport = MockTransport { _ in (200, "{}") }
        let client = JevClient(configuration: JevConfiguration(apiKey: "  "), transport: transport)
        do {
            _ = try await client.systemOne(state: .null, questions: ["q": .noul(instructions: "?")])
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? JevError, .missingAPIKey)
            XCTAssertTrue(transport.requests.isEmpty)
        }
    }
}

final class SuggestionPipelineTests: XCTestCase {

    let engine = SpellingEngine(lexicon: SpellingEngineTests.lexicon)

    func pipeline(_ transport: MockTransport?) -> SuggestionPipeline {
        let reranker = transport.map {
            JevReranker(client: JevClient(configuration: JevConfiguration(apiKey: "k"), transport: $0))
        }
        return SuggestionPipeline(engine: engine, reranker: reranker)
    }

    func testOnDeviceSuggestionsWorkWithoutJev() {
        let set = pipeline(nil).local(for: TypingContext(before: "I like it ", word: "becuz"))
        XCTAssertEqual(set.autocorrect, "because")
        XCTAssertEqual(set.suggestions.first?.kind, .keepTyped)
        XCTAssertEqual(set.suggestions.dropFirst().first?.text, "because")
        XCTAssertTrue(set.suggestions[1].isAutocorrect)
    }

    func testJevCanPickADifferentCandidateFromContext() async {
        // "I saw a big dab" – on-device can't tell, Jev picks "dog"... but only
        // among options the engine offered. Here: "dinosor" with a strong Jev pick.
        let p = pipeline(.answering("dinosaur", confidence: 0.95, typedIsIntended: 0.02))
        let local = p.local(for: TypingContext(before: "We saw a big ", word: "dinosor"))
        let refined = await p.refine(local)
        XCTAssertEqual(refined.source, .jev)
        XCTAssertEqual(refined.autocorrect, "dinosaur")
    }

    func testJevKeepsAWordTheWriterMeant() async {
        // Jev is confident the typed word is right: nothing is changed.
        let p = pipeline(.answering("becuz", confidence: 0.9, typedIsIntended: 0.95))
        let refined = await p.refine(p.local(for: TypingContext(before: "my band is called ", word: "becuz")))
        XCTAssertNil(refined.autocorrect)
    }

    func testRealWordMixUpsNeedVeryHighConfidence() async {
        let unsure = pipeline(.answering("there", confidence: 0.6, typedIsIntended: 0.3))
        let a = await unsure.refine(unsure.local(for: TypingContext(before: "I put it over ", word: "their")))
        XCTAssertNil(a.autocorrect)
        XCTAssertEqual(a.suggestions.dropFirst().first?.text, "there")

        let sure = pipeline(.answering("there", confidence: 0.97, typedIsIntended: 0.02))
        let b = await sure.refine(sure.local(for: TypingContext(before: "I put it over ", word: "their")))
        XCTAssertEqual(b.autocorrect, "there")
    }

    func testFailuresFallBackToOnDevice() async {
        let p = pipeline(MockTransport { _ in (500, "oops") })
        let local = p.local(for: TypingContext(before: "", word: "becuz"))
        let refined = await p.refine(local)
        XCTAssertEqual(refined, local)
    }

    func testSuggestOnlyModeNeverAutocorrects() {
        let p = pipeline(nil)
        p.mode = .suggestOnly
        let set = p.local(for: TypingContext(before: "", word: "becuz"))
        XCTAssertNil(set.autocorrect)
        XCTAssertTrue(set.suggestions.contains { $0.text == "because" })
    }

    func testReviewFixesAHomophoneOnceContextArrives() async {
        let p = pipeline(.answering("they're", confidence: 0.93, typedIsIntended: 0.04))
        let fix = await p.reviewRecentWords(textBefore: "I think their going ")
        XCTAssertEqual(fix?.kind, .fixPrevious)
        XCTAssertEqual(fix?.fix?.original, "their going ")
        XCTAssertEqual(fix?.fix?.replacement, "they're going ")
    }
}
