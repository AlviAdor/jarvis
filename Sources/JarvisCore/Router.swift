import Foundation

public struct Router: Sendable {
    public init() {}

    private static let screenWords = [
        "open ", "click", "type ", "scroll", "close ", "launch", "go to", "search for",
        "play ", "press ", "on my screen", "drag", "switch to", "start ", "take a screenshot",
        "what's on my screen", "what is on my screen",
    ]
    private static let webWords = [
        "latest", "news", "weather", "score", "price of", "stock", "today's", "who won",
        "release date", "right now", "this week", "currently",
    ]
    private static let hardWords = [
        "analyze", "analyse", "architect", "debug", "prove", "refactor", "strategy",
        "step by step", "write a detailed", "compare and contrast", "design a", "essay",
    ]

    /// Free first pass; returns nil when a model should decide.
    public func heuristic(_ text: String) -> Mode? {
        let s = text.lowercased()
        if Self.screenWords.contains(where: { s.contains($0) }) { return .screen }
        if Self.webWords.contains(where: { s.contains($0) }) { return .web }
        if Self.hardWords.contains(where: { s.contains($0) }) || s.split(separator: " ").count > 120 { return .hard }
        if s.split(separator: " ").count <= 6 { return .chat }
        return nil
    }

    public static let classifierPrompt = """
    Classify the user's request. Reply with exactly one word:
    chat - conversation, a simple question, or a task for tools like mail, notes, reminders, files
    web - needs current information from the internet
    screen - needs operating the computer (apps, clicking, typing, browsing)
    hard - complex reasoning, long writing, or code
    """

    public static func parse(_ answer: String) -> Mode {
        let a = answer.lowercased()
        for m in [Mode.screen, .web, .hard] where a.contains(m.rawValue) { return m }
        return .chat
    }

    public func tier(for mode: Mode, settings: JarvisSettings) -> Tier {
        if let forced = Tier(rawValue: settings.modelChoice) { return forced }
        switch mode {
        case .chat: return .lite
        case .web, .screen: return .flash
        case .hard: return .pro
        }
    }

    /// Model ids to try in order; later ones are cheaper fallbacks for rate limits.
    public func chain(for mode: Mode, settings: JarvisSettings, from override: Tier? = nil) -> [String] {
        var out: [String] = []
        var t: Tier? = override ?? tier(for: mode, settings: settings)
        while let cur = t {
            let id = settings.modelID(cur)
            if !out.contains(id) { out.append(id) }
            t = cur.fallback
        }
        return out
    }

    public func escalation(from mode: Mode, settings: JarvisSettings) -> Tier? {
        settings.modelChoice == "auto" && tier(for: mode, settings: settings) != .pro ? .pro : nil
    }
}
