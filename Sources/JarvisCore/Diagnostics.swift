import Foundation

public struct TestLine: Identifiable, Sendable {
    public enum Kind: Sendable { case ok, warn, fail }
    public let id = UUID()
    public let kind: Kind
    public let text: String

    public init(kind: Kind, text: String) {
        self.kind = kind
        self.text = text
    }
}

public enum Redact {
    /// Strips anything that looks like an API key before text reaches the screen or a log.
    public static func secrets(_ s: String) -> String {
        var out = s
        for pattern in ["AIza[0-9A-Za-z_\\-]{20,}", "sk-ant-[0-9A-Za-z_\\-]{10,}"] {
            out = out.replacingOccurrences(of: pattern, with: "[key]", options: .regularExpression)
        }
        return out
    }
}

public enum Friendly {
    /// Turns an API failure into one plain sentence.
    public static func message(_ error: Error) -> String {
        if case LLMError.http(let code, let body) = error {
            var detail = ""
            if let data = body.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let e = obj["error"] as? [String: Any], let m = e["message"] as? String {
                detail = m
            }
            let hint: String
            switch code {
            case 400: hint = "The request was rejected"
            case 401, 403: hint = "The key was refused"
            case 404: hint = "That model isn't available to this key"
            case 429: hint = "Rate limit or quota reached"
            case 500...599: hint = "The service is having trouble"
            default: hint = "Request failed (\(code))"
            }
            return Redact.secrets(detail.isEmpty ? hint : "\(hint): \(detail.prefix(220))")
        }
        return Redact.secrets(error.localizedDescription)
    }
}

public enum ModelPicker {
    private static let skip = ["image", "tts", "live", "audio", "embedding", "robotics", "computer-use", "exp", "latest", "customtools", "thinking"]

    /// Newest usable model for a tier from the account's own model list.
    public static func newest(_ tier: Tier, in models: [String]) -> String? {
        let word: String
        switch tier {
        case .lite: word = "flash-lite"
        case .flash: word = "flash"
        case .pro: word = "pro"
        }
        let pattern = "^gemini-(\\d+(?:\\.\\d+)?)-\(word)(-preview.*)?$"
        let ranked: [(String, Double, Bool)] = models.compactMap { id in
            guard !skip.contains(where: { id.contains($0) }),
                  let r = id.range(of: pattern, options: .regularExpression), r.lowerBound == id.startIndex else { return nil }
            let ver = id.dropFirst("gemini-".count).prefix { $0.isNumber || $0 == "." }
            guard let v = Double(ver) else { return nil }
            return (id, v, id.contains("preview"))
        }
        // Stable beats preview at the same version; Pro is often preview-only so it's allowed.
        return ranked.sorted { a, b in a.1 != b.1 ? a.1 > b.1 : (a.2 ? 1 : 0) < (b.2 ? 1 : 0) }.first?.0
    }
}

public enum ConnectionTest {
    public static func gemini(key: String, settings: JarvisSettings) async -> (lines: [TestLine], models: [String]) {
        var lines: [TestLine] = []
        guard !key.isEmpty else { return ([TestLine(kind: .fail, text: "No Gemini key entered.")], []) }
        let client = GeminiClient(apiKey: key)

        var models: [String] = []
        do {
            models = try await client.listModels()
            lines.append(TestLine(kind: .ok, text: "Key accepted. \(models.count) models available."))
        } catch {
            lines.append(TestLine(kind: .fail, text: Friendly.message(error)))
            return (lines, [])
        }

        for tier in Tier.allCases {
            let id = settings.modelID(tier)
            if models.contains(id) {
                lines.append(TestLine(kind: .ok, text: "\(tier.rawValue.capitalized): \(id) is available."))
            } else if let best = ModelPicker.newest(tier, in: models) {
                lines.append(TestLine(kind: .warn, text: "\(tier.rawValue.capitalized): \(id) isn't available to you. Newest that is: \(best)."))
            } else {
                lines.append(TestLine(kind: .warn, text: "\(tier.rawValue.capitalized): \(id) isn't available and no replacement was found."))
            }
        }

        // A real request on the model Jarvis uses most.
        let probe = models.contains(settings.flashModel) ? settings.flashModel : (ModelPicker.newest(.flash, in: models) ?? settings.flashModel)
        let started = Date()
        do {
            let r = try await client.generate(model: probe, system: "Reply with the single word OK.",
                                              contents: [["role": "user", "parts": [["text": "ping"]]]],
                                              maxTokens: 32, thinking: probe.contains("gemini-2") ? .budget(0) : .level("low"))
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lines.append(TestLine(kind: r.text.isEmpty ? .warn : .ok, text: "Test request to \(probe) worked in \(ms) ms."))
        } catch {
            lines.append(TestLine(kind: .fail, text: "Test request to \(probe) failed. \(Friendly.message(error))"))
        }
        return (lines, models)
    }

    public static func claude(key: String, model: String) async -> [TestLine] {
        guard !key.isEmpty else { return [TestLine(kind: .warn, text: "No Claude key entered. Gemini will be used.")] }
        let started = Date()
        do {
            _ = try await ClaudeClient(apiKey: key).send([
                "model": model, "max_tokens": 16,
                "messages": [["role": "user", "content": "ping"]],
            ])
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            return [TestLine(kind: .ok, text: "Claude \(model) worked in \(ms) ms.")]
        } catch {
            return [TestLine(kind: .fail, text: "Claude failed, so Jarvis will use Gemini. \(Friendly.message(error))")]
        }
    }
}
