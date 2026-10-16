import Foundation

public struct GeminiResponse: @unchecked Sendable {
    public var parts: [[String: Any]]
    public var usage: Usage
    public var searchQueries: [String] = []
    public var sources: [(title: String, url: String)] = []

    public var text: String {
        parts.compactMap { $0["text"] as? String }.joined()
    }

    public var calls: [(name: String, args: [String: Any], id: String?)] {
        parts.compactMap { p in
            guard let fc = p["functionCall"] as? [String: Any], let name = fc["name"] as? String else { return nil }
            return (name, fc["args"] as? [String: Any] ?? [:], fc["id"] as? String)
        }
    }
}

/// Gemini 2.x takes a token budget; Gemini 3.x takes a level. Sending both is a 400.
public enum Thinking: Sendable, Equatable {
    case budget(Int)
    case level(String)

    var json: [String: Any] {
        switch self {
        case .budget(let n): return ["thinkingBudget": n]
        case .level(let l): return ["thinkingLevel": l]
        }
    }
}

public final class GeminiClient: @unchecked Sendable {
    private let apiKey: String
    private static let base = "https://generativelanguage.googleapis.com/v1beta"

    public init(apiKey: String) { self.apiKey = apiKey }

    private func request(_ path: String, body: [String: Any]?) throws -> URLRequest {
        var req = URLRequest(url: URL(string: Self.base + path)!)
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 120
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    public func generate(model: String, system: String, contents: [[String: Any]], tools: [[String: Any]] = [],
                         maxTokens: Int = 1024, thinking: Thinking? = nil) async throws -> GeminiResponse {
        var gen: [String: Any] = ["maxOutputTokens": maxTokens]
        if let thinking { gen["thinkingConfig"] = thinking.json }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": gen,
        ]
        if !tools.isEmpty { body["tools"] = tools }
        let quota = Self.quotaKey(model, tools: tools)

        // Don't spend a request on a model Google has already said no to; the caller moves on.
        if !QuotaBook.shared.usable(quota) {
            let why = QuotaBook.shared.reason(quota).map { QuotaBook.describe(model, $0.kind, $0.until) } ?? "resting"
            throw LLMError.http(429, #"{"error":{"message":"\#(why)","status":"RESOURCE_EXHAUSTED"},"jarvis":"skipped"}"#)
        }
        var delay: UInt64 = 1_000_000_000
        var attempts = 0
        while true {
            try Task.checkCancellation()
            let (data, resp) = try await URLSession.shared.data(for: request("/models/\(model):generateContent", body: body))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""

            if code == 200 { return try Self.parse(data) }
            // Quota: note it and hand back at once, so the caller can move to another model without waiting.
            if code == 429 {
                QuotaBook.shared.note(quota, body: text)
                throw LLMError.http(code, text)
            }

            // Some models reject thinkingConfig; drop it and try again.
            if code == 400, text.lowercased().contains("thinking"), var g = body["generationConfig"] as? [String: Any],
               g["thinkingConfig"] != nil {
                g.removeValue(forKey: "thinkingConfig")
                body["generationConfig"] = g
                continue
            }
            attempts += 1
            if [500, 503].contains(code), attempts < 2 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            throw LLMError.http(code, text)
        }
    }

    /// Same request, streamed: `onText` gets the growing answer as Gemini writes it, so it can be shown
    /// (and spoken) before the whole reply is done. Anything unusual falls back to the plain request.
    /// Google Search has its own allowance: a refused search pauses searching on that model, not the model itself.
    public static func quotaKey(_ model: String, tools: [[String: Any]]) -> String {
        tools.contains { $0["google_search"] != nil } ? model + "+search" : model
    }

    /// Whether this model can search with Google right now, as far as Jarvis knows.
    public static func canSearch(_ model: String) -> Bool {
        QuotaBook.shared.usable(model) && QuotaBook.shared.usable(model + "+search")
    }

    public func stream(model: String, system: String, contents: [[String: Any]], tools: [[String: Any]] = [],
                       maxTokens: Int = 1024, thinking: Thinking? = nil,
                       onText: @escaping @Sendable (String) -> Void) async throws -> GeminiResponse {
        if !QuotaBook.shared.usable(model) {
            return try await generate(model: model, system: system, contents: contents, tools: tools, maxTokens: maxTokens, thinking: thinking)
        }
        var gen: [String: Any] = ["maxOutputTokens": maxTokens]
        if let thinking { gen["thinkingConfig"] = thinking.json }
        var body: [String: Any] = ["systemInstruction": ["parts": [["text": system]]], "contents": contents, "generationConfig": gen]
        if !tools.isEmpty { body["tools"] = tools }
        let quota = Self.quotaKey(model, tools: tools)
        var req = try request("/models/\(model):streamGenerateContent?alt=sse", body: body)
        req.timeoutInterval = 120
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            var text = ""
            for try await line in bytes.lines { text += line; if text.count > 4000 { break } }
            if code == 429 {
                QuotaBook.shared.note(quota, body: text)
                throw LLMError.http(code, text)
            }
            // Let the plain request deal with retries and settings the model doesn't take.
            return try await generate(model: model, system: system, contents: contents, tools: tools, maxTokens: maxTokens, thinking: thinking)
        }
        var parts: [[String: Any]] = []
        var shown = ""
        var usage = Usage()
        var queries: [String] = []
        var sources: [(title: String, url: String)] = []
        var blocked = ""
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:"),
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
            if let meta = obj["usageMetadata"] as? [String: Any] {
                usage = Usage(input: meta["promptTokenCount"] as? Int ?? 0, output: meta["candidatesTokenCount"] as? Int ?? 0)
            }
            if let why = (obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String { blocked = why }
            guard let cand = (obj["candidates"] as? [[String: Any]])?.first else { continue }
            let new = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
            parts += new
            for p in new where p["thought"] as? Bool != true {
                if let t = p["text"] as? String { shown += t }
            }
            if !new.isEmpty, !shown.isEmpty { onText(shown) }
            if let gm = cand["groundingMetadata"] as? [String: Any] {
                queries = gm["webSearchQueries"] as? [String] ?? queries
                let found: [(title: String, url: String)] = (gm["groundingChunks"] as? [[String: Any]] ?? []).compactMap { c in
                    guard let web = c["web"] as? [String: Any], let uri = web["uri"] as? String else { return nil }
                    return (web["title"] as? String ?? uri, uri)
                }
                if !found.isEmpty { sources = found }
            }
        }
        if parts.isEmpty { throw LLMError.refused(blocked) }
        var r = GeminiResponse(parts: parts, usage: usage)
        r.searchQueries = queries
        r.sources = sources
        return r
    }

    private static func parse(_ data: Data) throws -> GeminiResponse {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse }
        let meta = obj["usageMetadata"] as? [String: Any]
        let usage = Usage(input: meta?["promptTokenCount"] as? Int ?? 0, output: meta?["candidatesTokenCount"] as? Int ?? 0)
        guard let cand = (obj["candidates"] as? [[String: Any]])?.first else {
            let why = (obj["promptFeedback"] as? [String: Any])?["blockReason"] as? String ?? ""
            throw LLMError.refused(why)
        }
        let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        if parts.isEmpty, let reason = cand["finishReason"] as? String, reason != "STOP" {
            throw LLMError.refused(reason)
        }
        var r = GeminiResponse(parts: parts, usage: usage)
        if let gm = cand["groundingMetadata"] as? [String: Any] {
            r.searchQueries = gm["webSearchQueries"] as? [String] ?? []
            r.sources = (gm["groundingChunks"] as? [[String: Any]] ?? []).compactMap { c in
                guard let web = c["web"] as? [String: Any], let uri = web["uri"] as? String else { return nil }
                return (web["title"] as? String ?? uri, uri)
            }
        }
        return r
    }

    /// Model ids that support generateContent, for the settings pickers.
    public func listModels() async throws -> [String] {
        let (data, resp) = try await URLSession.shared.data(for: request("/models?pageSize=200", body: nil))
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let models = obj?["models"] as? [[String: Any]] ?? []
        return models
            .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
            .compactMap { ($0["name"] as? String)?.replacingOccurrences(of: "models/", with: "") }
            .filter { $0.hasPrefix("gemini") }
            .sorted()
    }

    public static func imagePart(_ jpeg: Data) -> [String: Any] {
        ["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
}
