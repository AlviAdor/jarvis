import Foundation

public enum LLMError: Error, LocalizedError {
    case missingKey(Provider)
    case http(Int, String)
    case refused
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .missingKey(let p): return "No API key set for \(p.rawValue)."
        case .http(let code, let body): return "Request failed (\(code)): \(body.prefix(300))"
        case .refused: return "The model declined this request."
        case .badResponse: return "Unexpected response from the API."
        }
    }
}

public struct ChatTurn: Sendable {
    public var role: String
    public var text: String
    public var jpeg: Data?
    public init(role: String, text: String, jpeg: Data? = nil) {
        self.role = role
        self.text = text
        self.jpeg = jpeg
    }
}

public struct LLMReply: Sendable {
    public var text: String
    public var usage: Usage
}

public final class ClaudeClient: @unchecked Sendable {
    private let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    public func send(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse }
        if obj["stop_reason"] as? String == "refusal" { throw LLMError.refused }
        return obj
    }

    public static func usage(_ obj: [String: Any]) -> Usage {
        let u = obj["usage"] as? [String: Any]
        return Usage(input: u?["input_tokens"] as? Int ?? 0, output: u?["output_tokens"] as? Int ?? 0)
    }

    public func complete(model: String, system: String, turns: [ChatTurn], maxTokens: Int = 1024) async throws -> LLMReply {
        let messages: [[String: Any]] = turns.map { t in
            var blocks: [[String: Any]] = []
            if let jpeg = t.jpeg {
                blocks.append(Self.imageBlock(jpeg))
            }
            blocks.append(["type": "text", "text": t.text])
            return ["role": t.role, "content": blocks]
        }
        let obj = try await send([
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": messages,
        ])
        let text = (obj["content"] as? [[String: Any]] ?? [])
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return LLMReply(text: text, usage: Self.usage(obj))
    }

    public static func imageBlock(_ jpeg: Data) -> [String: Any] {
        [
            "type": "image",
            "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()],
        ]
    }
}

public final class GeminiClient: @unchecked Sendable {
    private let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    public func complete(model: String, system: String, turns: [ChatTurn], maxTokens: Int = 1024) async throws -> LLMReply {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120

        let contents: [[String: Any]] = turns.map { t in
            var parts: [[String: Any]] = [["text": t.text]]
            if let jpeg = t.jpeg {
                parts.append(["inline_data": ["mime_type": "image/jpeg", "data": jpeg.base64EncodedString()]])
            }
            return ["role": t.role == "assistant" ? "model" : "user", "parts": parts]
        }
        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": contents,
            "generationConfig": ["maxOutputTokens": maxTokens],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cand = (obj["candidates"] as? [[String: Any]])?.first else { throw LLMError.badResponse }
        let parts = (cand["content"] as? [String: Any])?["parts"] as? [[String: Any]] ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined()
        let meta = obj["usageMetadata"] as? [String: Any]
        let usage = Usage(input: meta?["promptTokenCount"] as? Int ?? 0, output: meta?["candidatesTokenCount"] as? Int ?? 0)
        return LLMReply(text: text, usage: usage)
    }
}

/// Dispatches to the right provider using keys held in the Keychain-backed store.
public struct Hub: Sendable {
    public let claude: ClaudeClient?
    public let gemini: GeminiClient?

    public init(claudeKey: String, geminiKey: String) {
        claude = claudeKey.isEmpty ? nil : ClaudeClient(apiKey: claudeKey)
        gemini = geminiKey.isEmpty ? nil : GeminiClient(apiKey: geminiKey)
    }

    public var available: Set<Provider> {
        var s = Set<Provider>()
        if claude != nil { s.insert(.anthropic) }
        if gemini != nil { s.insert(.google) }
        return s
    }

    public func complete(_ spec: ModelSpec, system: String, turns: [ChatTurn], maxTokens: Int = 1024) async throws -> LLMReply {
        switch spec.provider {
        case .anthropic:
            guard let c = claude else { throw LLMError.missingKey(.anthropic) }
            return try await c.complete(model: spec.id, system: system, turns: turns, maxTokens: maxTokens)
        case .google:
            guard let g = gemini else { throw LLMError.missingKey(.google) }
            return try await g.complete(model: spec.id, system: system, turns: turns, maxTokens: maxTokens)
        }
    }
}
