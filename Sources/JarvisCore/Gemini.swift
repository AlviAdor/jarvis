import Foundation

public struct GeminiResponse: @unchecked Sendable {
    public var parts: [[String: Any]]
    public var usage: Usage

    public var text: String {
        parts.compactMap { $0["text"] as? String }.joined()
    }

    public var calls: [(name: String, args: [String: Any])] {
        parts.compactMap { p in
            guard let fc = p["functionCall"] as? [String: Any], let name = fc["name"] as? String else { return nil }
            return (name, fc["args"] as? [String: Any] ?? [:])
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
                         maxTokens: Int = 1024, thinkingBudget: Int? = nil) async throws -> GeminiResponse {
        var gen: [String: Any] = ["maxOutputTokens": maxTokens]
        if let thinkingBudget { gen["thinkingConfig"] = ["thinkingBudget": thinkingBudget] }
        var body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": gen,
        ]
        if !tools.isEmpty { body["tools"] = tools }

        var delay: UInt64 = 1_000_000_000
        var attempts = 0
        while true {
            try Task.checkCancellation()
            let (data, resp) = try await URLSession.shared.data(for: request("/models/\(model):generateContent", body: body))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let text = String(data: data, encoding: .utf8) ?? ""

            if code == 200 { return try Self.parse(data) }

            // Some models reject thinkingConfig; drop it and try again.
            if code == 400, text.lowercased().contains("thinking"), var g = body["generationConfig"] as? [String: Any],
               g["thinkingConfig"] != nil {
                g.removeValue(forKey: "thinkingConfig")
                body["generationConfig"] = g
                continue
            }
            attempts += 1
            if [429, 500, 503].contains(code), attempts < 3 {
                try await Task.sleep(nanoseconds: delay)
                delay *= 2
                continue
            }
            throw LLMError.http(code, text)
        }
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
        return GeminiResponse(parts: parts, usage: usage)
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
