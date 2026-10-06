import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A small client for TypeSafe's System One API (`POST /v1/systemone`), which
// serves the Jev model. Jev doesn't write text: it takes a `state` plus named,
// typed questions and returns calibrated, typed answers. The wire format here
// mirrors TypeSafe's official SDK (@typesafe-ai/sdk 0.6).

/// Any JSON value, used for Jev's free-form `state`.
public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let v): try container.encode(v)
        case .number(let v): try container.encode(v)
        case .bool(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .null: try container.encodeNil()
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let v = try? container.decode(Bool.self) { self = .bool(v) }
        else if let v = try? container.decode(Double.self) { self = .number(v) }
        else if let v = try? container.decode(String.self) { self = .string(v) }
        else if let v = try? container.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try container.decode([JSONValue].self)) }
    }
}

/// A typed question for Jev.
public enum JevQuestion: Sendable, Equatable, Encodable {
    /// Yes/no; answered with the probability of "yes".
    case noul(instructions: String, whenTrue: String? = nil, whenFalse: String? = nil)
    /// Pick one label; answered with the label, its confidence and a probability per label.
    case choice(instructions: String, options: [String: String?])
    /// Place on an ordered rubric (at least two levels, scored from 0).
    case score(instructions: String, levels: [String?])

    private enum CodingKeys: String, CodingKey { case type, instructions, criteria }
    private enum NoulCriteriaKeys: String, CodingKey { case yes = "true", no = "false" }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .noul(instructions, whenTrue, whenFalse):
            try c.encode("noul", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            if whenTrue != nil || whenFalse != nil {
                var criteria = c.nestedContainer(keyedBy: NoulCriteriaKeys.self, forKey: .criteria)
                try criteria.encodeIfPresent(whenTrue, forKey: .yes)
                try criteria.encodeIfPresent(whenFalse, forKey: .no)
            }
        case let .choice(instructions, options):
            try c.encode("choice", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(options.mapValues { $0.map(JSONValue.string) ?? .null }, forKey: .criteria)
        case let .score(instructions, levels):
            try c.encode("score", forKey: .type)
            try c.encode(instructions, forKey: .instructions)
            try c.encode(levels.map { $0.map(JSONValue.string) ?? .null }, forKey: .criteria)
        }
    }
}

/// A typed answer from Jev.
public enum JevAnswer: Sendable, Equatable, Decodable {
    case noul(probability: Double)
    case choice(label: String, confidence: Double, probabilities: [String: Double])
    case score(value: Double, confidence: Double, probabilities: [String: Double])

    private enum CodingKeys: String, CodingKey { case type, noul, choice, score, confidence, probabilities }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "noul":
            self = .noul(probability: try c.decode(Double.self, forKey: .noul))
        case "choice":
            self = .choice(
                label: try c.decode(String.self, forKey: .choice),
                confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0,
                probabilities: try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
            )
        case "score":
            self = .score(
                value: try c.decode(Double.self, forKey: .score),
                confidence: try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 0,
                probabilities: try c.decodeIfPresent([String: Double].self, forKey: .probabilities) ?? [:]
            )
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown answer type \(other)")
        }
    }
}

public struct SystemOneResponse: Sendable, Decodable {
    public let model: String?
    public let answers: [String: JevAnswer]
}

public enum JevError: Error, Equatable, LocalizedError {
    case missingAPIKey
    case http(status: Int, message: String)
    case invalidResponse
    case decoding(String)
    case missingAnswer(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey: return "Add your TypeSafe API key to use Jev."
        case let .http(status, message): return "TypeSafe returned HTTP \(status): \(message)"
        case .invalidResponse: return "TypeSafe sent an unexpected response."
        case let .decoding(detail): return "Couldn't read TypeSafe's answer: \(detail)"
        case let .missingAnswer(name): return "TypeSafe didn't answer \"\(name)\"."
        }
    }
}

public struct JevConfiguration: Sendable, Equatable {
    public var apiKey: String
    public var baseURL: URL
    public var model: String
    /// Keyboards must stay snappy: Jev normally answers in 70–500 ms.
    public var timeout: TimeInterval

    public init(apiKey: String,
                baseURL: URL = URL(string: "https://api.typesafe.ai")!,
                model: String = "jev-latest",
                timeout: TimeInterval = 2.0) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
    }
}

public protocol JevTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: JevTransport, @unchecked Sendable {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw JevError.invalidResponse }
        return (data, http)
    }
}

public struct JevClient: Sendable {
    public var configuration: JevConfiguration
    public var transport: JevTransport

    public init(configuration: JevConfiguration, transport: JevTransport = URLSessionTransport()) {
        self.configuration = configuration
        self.transport = transport
    }

    struct RequestBody: Encodable {
        let model: String
        let state: JSONValue
        let questions: [String: JevQuestion]
    }

    func makeRequest(state: JSONValue, questions: [String: JevQuestion]) throws -> URLRequest {
        guard !configuration.apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw JevError.missingAPIKey }
        var request = URLRequest(url: configuration.baseURL.appendingPathComponent("v1/systemone"))
        request.httpMethod = "POST"
        request.timeoutInterval = configuration.timeout
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Lexia-Keyboard/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(
            RequestBody(model: configuration.model, state: state, questions: questions)
        )
        return request
    }

    /// Asks Jev the named questions about `state`.
    public func systemOne(state: JSONValue, questions: [String: JevQuestion]) async throws -> SystemOneResponse {
        let request = try makeRequest(state: state, questions: questions)
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let message = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw JevError.http(status: response.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(SystemOneResponse.self, from: data)
        } catch {
            throw JevError.decoding(String(describing: error))
        }
    }
}
