import Foundation

public struct Router: Sendable {
    public init() {}

    private static let screenWords = [
        "open ", "click", "scroll", "close ", "go to", "search for", "press ", "on my screen", "drag",
        "switch to", "take a screenshot", "what's on my screen", "what is on my screen", "fill in", "fill out",
    ]
    private static let webWords = [
        "latest", "news", "weather", "score", "price of", "stock", "today's", "who won",
        "release date", "right now", "this week", "currently",
    ]
    private static let hardWords = [
        "analyze", "analyse", "architect", "debug", "prove", "refactor", "strategy",
        "step by step", "write a detailed", "compare and contrast", "design a", "essay",
        "think hard", "think carefully", "in depth", "deep dive", "thoroughly", "take your time",
    ]

    private static let toolWords = [
        "remember", "remind", "schedule", "every day", "every morning", "every evening", "every week",
        "timer", "alarm", "email", "e-mail", " mail", "inbox", "file", "folder", "document", "clipboard",
        "copy ", "paste", "download", "git ", "repo", "command", "terminal", " open ", " quit ", " launch",
        " type ", "clean", "free up", "organi", "tidy", "duplicate", "trash", "calendar", "meeting",
        " event", "appointment", "agenda", "reminder", "contact", "phone number", " note", "imessage",
        " message ", " text ", " music", " song", " play", " pause", " skip", "volume", " mute", "brightness",
        "dark mode", "light mode", "wi-fi", "wifi", "shortcut", " lock ", "lock the", "lock my", "setting",
        " forget", "briefing", "brief me", " pdf", "find my", "running apps", "what apps",
    ]

    private static let macWords = [
        "battery", "storage", "disk space", "free space", "hard drive", " ssd", "memory usage", " ram",
        " cpu", "processor", "temperature", "overheat", "hot", "my mac", "this mac", "uptime", "fan",
        "running slow", "so slow", "laggy", "health of", "system status", "how much space",
    ]

    /// Requests that need Jarvis's tools skip the local model, which can't use them.
    public static func needsTools(_ text: String) -> Bool {
        let s = " " + text.lowercased() + " "
        return toolWords.contains { s.contains($0) }
    }

    private static let followOpeners = [
        "and ", "what about", "how about", "also ", "then ", "but ", "so ", "ok ", "okay", "yes", "yeah", "no,", "nope",
        "do it", "go ahead", "do that", "same for", "the same", "again", "more", "tell me more", "why", "what else",
        "and then", "instead", "actually", "that one", "this one", "the first", "the second", "the last", "send it", "open it",
    ]
    private static let backReferences = [" it", " it?", " that", " this", " them", " those", " these", " there", " he ", " she ", " they",
                                         " him", " her", " his ", " its ", " one ", " ones", " same", " instead", " again", " too"]

    /// Short messages that only make sense next to the previous one: "and tomorrow?", "send it to her".
    public static func isFollowUp(_ text: String) -> Bool {
        let s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let words = s.split(separator: " ").count
        guard words <= 9 else { return false }
        if followOpeners.contains(where: { s.hasPrefix($0) }) { return true }
        let padded = " " + s + " "
        return words <= 6 && backReferences.contains { padded.contains($0) }
    }

    private static let depthWords = [
        "why", "how does", "how do", "how can", "how should", "explain", "difference between", "compare", "should i",
        "what if", "pros and cons", "help me", "plan", "write", "solve", "calculate", "prove", "summarise", "summarize",
        "advice", "recommend", "teach me", "step by step", "analyse", "analyze", "review", "translate", "draft",
    ]

    /// Questions that deserve a stronger model than the quick one: reasoning, advice, writing, anything long.
    public static func isSubstantive(_ text: String) -> Bool {
        let s = text.lowercased()
        return s.split(separator: " ").count >= 12 || depthWords.contains { s.contains($0) }
    }

    /// Questions about the Mac itself. The local model can answer these from a live reading.
    public static func isMacStatus(_ text: String) -> Bool {
        let s = " " + text.lowercased() + " "
        let acting = ["clean", "free up", "delete", "organi", "remove", "tidy", "empty", "quit", "close"].contains { s.contains($0) }
        return !acting && macWords.contains { s.contains($0) }
    }

    /// Free first pass; returns nil when a model should decide.
    public func heuristic(_ text: String) -> Mode? {
        let s = text.lowercased()
        let words = s.split(separator: " ")
        // "Open Safari" alone is one tool call; no need to look at the screen.
        if s.hasPrefix("open "), words.count <= 3, !s.contains(".") { return .chat }
        if Self.screenWords.contains(where: { s.contains($0) }) { return .screen }
        if Self.webWords.contains(where: { s.contains($0) }) { return .web }
        if Self.hardWords.contains(where: { s.contains($0) }) || s.split(separator: " ").count > 120 { return .hard }
        if s.split(separator: " ").count <= 6 { return .chat }
        return nil
    }

    public static let classifierPrompt = """
    Classify the user's latest request, reading it as a continuation of the previous exchange if one is given. Reply with exactly one word:
    chat - conversation, a simple question, or a task for tools: mail, calendar, reminders, notes, messages, files, music, volume, settings, disk cleanup, the Mac's health
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
        case .chat, .web: return .lite     // Lite models have the most generous free allowance
        case .screen: return .flash
        case .hard: return settings.usageSaver ? .flash : .pro
        }
    }

    /// The order tiers are tried in: the chosen one first, then lighter ones, and for everyday chat and
    /// search a step up to Flash too, so running out of Lite requests doesn't stop Jarvis.
    func tierOrder(from start: Tier, mode: Mode, saver: Bool = false) -> [Tier] {
        var out: [Tier] = []
        var t: Tier? = start
        while let cur = t { out.append(cur); t = cur.fallback }
        if start == .lite, mode == .chat || mode == .web, !saver { out.append(.flash) }
        return out
    }

    /// Model ids to try in order. Each tier's chosen model comes first, then up to two other models of the
    /// same tier (each has its own free allowance), then the lighter tiers.
    public func chain(for mode: Mode, settings: JarvisSettings, from override: Tier? = nil) -> [String] {
        var out: [String] = []
        for cur in tierOrder(from: override ?? tier(for: mode, settings: settings), mode: mode, saver: settings.usageSaver) {
            let ids = [settings.modelID(cur)] + ModelPicker.ranked(cur, in: settings.knownModels).prefix(4)
            for id in ids where !out.contains(id) { out.append(id) }
        }
        return out
    }

    public func escalation(from mode: Mode, settings: JarvisSettings) -> Tier? {
        settings.modelChoice == "auto" && tier(for: mode, settings: settings) != .pro ? .pro : nil
    }
}
