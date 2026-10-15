import Foundation

public struct Usage: Sendable {
    public var input = 0
    public var output = 0
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public enum Tier: String, CaseIterable, Codable, Sendable {
    case lite, flash, pro

    public var fallback: Tier? {
        switch self {
        case .lite: return nil
        case .flash: return .lite
        case .pro: return .flash
        }
    }
}

public enum Mode: String, Sendable {
    case chat, web, screen, hard
}

public enum LLMError: Error, LocalizedError {
    case missingKey
    case http(Int, String)
    case refused(String)
    case badResponse
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "No Gemini API key is set."
        case .http(let code, let body): return "Gemini request failed (\(code)): \(body.prefix(300))"
        case .refused(let why): return "Gemini declined this request. \(why)"
        case .badResponse: return "Unexpected response from Gemini."
        case .other(let s): return s
        }
    }
}

public struct AgentOutcome: Sendable {
    public let success: Bool
    public let summary: String
    public init(success: Bool, summary: String) {
        self.success = success
        self.summary = summary
    }
}

/// Counts requests and tokens per day so the free tier's limits stay visible.
@MainActor
public final class UsageTracker: ObservableObject {
    @Published public private(set) var requests = 0
    @Published public private(set) var tokens = 0

    private var day = ""

    public init() { load() }

    private static func today() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func load() {
        day = Self.today()
        requests = UserDefaults.standard.integer(forKey: "jarvis.req." + day)
        tokens = UserDefaults.standard.integer(forKey: "jarvis.tok." + day)
    }

    public func add(_ u: Usage) {
        if day != Self.today() { load() }
        requests += 1
        tokens += u.input + u.output
        UserDefaults.standard.set(requests, forKey: "jarvis.req." + day)
        UserDefaults.standard.set(tokens, forKey: "jarvis.tok." + day)
    }

    public func overCap(_ cap: Int) -> Bool {
        if day != Self.today() { load() }
        return requests >= cap
    }
}
