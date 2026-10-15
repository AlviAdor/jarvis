import Foundation

public enum Provider: String, Codable, Sendable {
    case anthropic, google
}

public struct ModelSpec: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let provider: Provider
    public let inputPerMTok: Double
    public let outputPerMTok: Double

    public func cost(_ u: Usage) -> Double {
        Double(u.input) / 1_000_000 * inputPerMTok + Double(u.output) / 1_000_000 * outputPerMTok
    }
}

public struct Usage: Sendable {
    public var input = 0
    public var output = 0
    public init(input: Int = 0, output: Int = 0) {
        self.input = input
        self.output = output
    }
}

public enum Catalog {
    public static let haiku = ModelSpec(id: "claude-haiku-5-5", name: "Haiku 5.5", provider: .anthropic, inputPerMTok: 0.10, outputPerMTok: 0.50)
    public static let sonnet = ModelSpec(id: "claude-sonnet-5-5", name: "Sonnet 5.5", provider: .anthropic, inputPerMTok: 2, outputPerMTok: 10)
    public static let opus = ModelSpec(id: "claude-opus-5-5", name: "Opus 5.5", provider: .anthropic, inputPerMTok: 4, outputPerMTok: 20)

    // Gemini ids are editable in settings; the free tier is treated as zero cost.
    public static func geminiFast(_ s: JarvisSettings) -> ModelSpec {
        ModelSpec(id: s.geminiFastModel, name: "Gemini Fast", provider: .google, inputPerMTok: 0, outputPerMTok: 0)
    }
    public static func geminiPro(_ s: JarvisSettings) -> ModelSpec {
        ModelSpec(id: s.geminiProModel, name: "Gemini Pro", provider: .google, inputPerMTok: 0, outputPerMTok: 0)
    }

    public static func all(_ s: JarvisSettings) -> [ModelSpec] {
        [geminiFast(s), geminiPro(s), haiku, sonnet, opus]
    }

    public static func spec(id: String, _ s: JarvisSettings) -> ModelSpec? {
        all(s).first { $0.id == id }
    }
}
