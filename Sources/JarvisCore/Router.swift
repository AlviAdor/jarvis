import Foundation

public enum Difficulty: String, Sendable {
    case chat, screen, hard
}

public struct Route: Sendable {
    public let model: ModelSpec
    public let difficulty: Difficulty
    public let reason: String
}

public struct Router: Sendable {
    public init() {}

    private static let screenWords = [
        "open ", "click", "type ", "scroll", "close ", "launch", "go to", "search for",
        "play ", "press ", "on my screen", "drag", "switch to", "start ", "take a screenshot",
    ]
    private static let hardWords = [
        "analyze", "analyse", "architect", "debug", "prove", "refactor", "strategy",
        "step by step", "write a detailed", "compare and contrast", "design a",
    ]

    /// Free, zero-token first pass. Returns nil when a model should decide.
    public func heuristic(_ text: String) -> Difficulty? {
        let s = text.lowercased()
        if Self.screenWords.contains(where: { s.contains($0) }) { return .screen }
        let words = s.split(separator: " ").count
        if Self.hardWords.contains(where: { s.contains($0) }) || words > 120 { return .hard }
        if words <= 6 { return .chat }
        return nil
    }

    public static let classifierPrompt = """
    Classify the user's request. Reply with exactly one word:
    chat - conversation or a simple question
    screen - needs operating the computer (opening apps, clicking, typing, browsing)
    hard - complex reasoning, long writing, or code
    """

    public static func parse(_ answer: String) -> Difficulty {
        let a = answer.lowercased()
        if a.contains("screen") { return .screen }
        if a.contains("hard") { return .hard }
        return .chat
    }

    /// Cheapest capable model for a lightweight call (classification, chat).
    public func cheapest(available: Set<Provider>, settings: JarvisSettings) -> ModelSpec? {
        let free = Catalog.geminiFast(settings)
        if available.contains(.google), settings.preferFreeTier || !available.contains(.anthropic) { return free }
        if available.contains(.anthropic) { return Catalog.haiku }
        return nil
    }

    public func pick(_ d: Difficulty, available: Set<Provider>, settings: JarvisSettings) -> Route? {
        if settings.modelChoice != "auto",
           let spec = Catalog.spec(id: settings.modelChoice, settings),
           available.contains(spec.provider) {
            return Route(model: spec, difficulty: d, reason: "chosen in settings")
        }
        guard let cheap = cheapest(available: available, settings: settings) else { return nil }
        let claude = available.contains(.anthropic)
        switch d {
        case .chat:
            return Route(model: cheap, difficulty: d, reason: "light task")
        case .screen:
            return Route(model: claude ? Catalog.sonnet : cheap, difficulty: d, reason: "screen control")
        case .hard:
            if claude { return Route(model: Catalog.opus, difficulty: d, reason: "hard reasoning") }
            return Route(model: Catalog.geminiPro(settings), difficulty: d, reason: "hard reasoning")
        }
    }

    public func escalate(_ spec: ModelSpec, available: Set<Provider>) -> ModelSpec? {
        guard available.contains(.anthropic) else { return nil }
        switch spec.id {
        case Catalog.opus.id: return nil
        case Catalog.sonnet.id: return Catalog.opus
        default: return Catalog.sonnet
        }
    }
}
