import Foundation

/// The getting-to-know-you conversation: Jarvis asks, the user answers out loud, and the answers
/// fill in their profile while the way they speak teaches Jarvis their voice.
public enum Interview {
    public enum Field: String, Sendable, CaseIterable { case name, work, place, focus, style, notes, voice }

    public struct Question: Sendable, Equatable {
        public let field: Field
        public let text: String
        public init(field: Field, text: String) {
            self.field = field
            self.text = text
        }
    }

    public static let focusOptions = ["Studies", "Work", "Coding", "Email and messages", "Calendar and reminders",
                                      "Keeping my Mac healthy", "Music and media", "News and research", "Writing", "Files and organising"]

    /// The questions, personalised with the name once it's known.
    public static func questions(name: String) -> [Question] {
        let n = name.isEmpty ? "" : ", \(name)"
        return [
            Question(field: .name, text: "Hi, I'm Jarvis. Before we start, what should I call you?"),
            Question(field: .work, text: "Nice to meet you\(n). What do you do? Are you studying, working, or something else?"),
            Question(field: .place, text: "Where are you based? It helps me with the weather, the time and places nearby."),
            Question(field: .focus, text: "What would you like my help with most? For example your studies, coding, email, your calendar, or keeping this Mac in shape."),
            Question(field: .style, text: "When I answer, do you prefer it short and quick, or with more detail?"),
            Question(field: .notes, text: "Last one. Is there anything else I should know about you? Hobbies, people in your life, or how you like things done."),
        ]
    }

    /// Extra prompts, used only when Jarvis still needs more of the user's voice.
    public static let voicePrompts = [
        "To get to know your voice a little better, tell me what you did today.",
        "And now say something you might ask me, like what the weather will be tomorrow.",
        "One more, please. Tell me about a place you'd like to visit.",
    ]

    public static let samplesNeeded = 5

    // MARK: Understanding answers on the spot

    static func strip(_ text: String, prefixes: [String]) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lower = t.lowercased()
        for p in prefixes.sorted(by: { $0.count > $1.count }) where lower.hasPrefix(p) {
            t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            break
        }
        return t
    }

    /// "No", "nothing else", "no, that's it": short answers that mean the user has nothing to add.
    static func skipped(_ text: String) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "[^a-z' ]", with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
        guard !t.isEmpty else { return true }
        guard t.split(separator: " ").count <= 5 else { return false }
        return ["no", "nope", "nah", "nothing", "not really", "no thanks", "skip", "pass", "none"].contains(t)
            || ["no ", "nope ", "nothing", "not really"].contains(where: t.hasPrefix)
            || ["that's it", "that's all", "nothing else"].contains(where: t.contains)
    }

    public static func name(from text: String) -> String {
        let t = strip(text, prefixes: ["you can call me", "please call me", "call me", "my name is", "my name's", "i'm called", "i am", "i'm", "it's", "this is", "just", "hi", "hello"])
        let words = t.split(separator: " ").map(String.init).filter { !["and", "but", "please", "thanks", "thank", "you"].contains($0.lowercased()) }
        guard let first = words.first else { return "" }
        let picked = words.count > 1 && words[1].first?.isUppercase == true ? [first, words[1]] : [first]
        return picked.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    public static func work(from text: String) -> String {
        skipped(text) ? "" : strip(text, prefixes: ["i'm a", "i am a", "i'm an", "i am an", "i work as a", "i work as an", "i work as", "i work at", "i work in", "i'm", "i am", "i", "currently"])
    }

    public static func place(from text: String) -> String {
        skipped(text) ? "" : strip(text, prefixes: ["i'm based in", "i am based in", "i live in", "i'm in", "i am in", "i'm from", "i am from", "based in", "from", "in", "near"])
    }

    static let focusWords: [(String, [String])] = [
        ("Studies", ["stud", "university", "college", "exam", "class", "assignment", "thesis", "homework"]),
        ("Work", ["work", "job", "office", "meeting", "client"]),
        ("Coding", ["code", "coding", "program", "develop", "swift", "python", "debug"]),
        ("Email and messages", ["email", "mail", "message", "inbox", "text"]),
        ("Calendar and reminders", ["calendar", "schedule", "remind", "appointment", "plan"]),
        ("Keeping my Mac healthy", ["mac", "computer", "storage", "battery", "disk", "space", "shape", "clean"]),
        ("Music and media", ["music", "song", "spotify", "video", "media"]),
        ("News and research", ["news", "research", "search", "information", "learn"]),
        ("Writing", ["writ", "essay", "report", "document"]),
        ("Files and organising", ["file", "organi", "folder", "tidy"]),
    ]

    public static func focus(from text: String) -> [String] {
        let t = text.lowercased()
        return focusWords.filter { _, words in words.contains { t.contains($0) } }.map(\.0)
    }

    public static func style(from text: String) -> String {
        let t = text.lowercased()
        if ["short", "brief", "quick", "concise", "to the point", "simple"].contains(where: t.contains) && !t.contains("detail") { return "brief" }
        if ["detail", "long", "thorough", "explain", "depth", "more"].contains(where: t.contains) { return "detailed" }
        return "balanced"
    }

    public static func notes(from text: String) -> String {
        skipped(text) ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Tidying it all up with Gemini

    public struct Profile: Sendable, Equatable {
        public var name = ""
        public var work = ""
        public var place = ""
        public var focus: [String] = []
        public var style = ""
        public var notes = ""
        public var facts: [String] = []
        public init() {}
    }

    static let extractInstructions = """
    You turn a short getting-to-know-you conversation between a voice assistant and its user into a profile.
    Speech recognition may have misheard words; fix obvious mistakes. Reply with JSON only, no code fences:
    {"name": "", "work": "", "place": "", "focus": [], "style": "", "notes": "", "facts": []}
    focus uses only these values: \(focusOptions.joined(separator: ", ")).
    style is brief, balanced or detailed. work is a short phrase (e.g. "Computer science student at AIUB"). place is "City, Country" when known.
    notes is one or two sentences of other lasting details. facts are short third-person sentences starting with "User" about people, hobbies and habits.
    Leave a field empty when the user didn't say. Never include passwords, card numbers or similar secrets.
    """

    public static func parseProfile(_ text: String) -> Profile? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        var p = Profile()
        func str(_ k: String) -> String { (obj[k] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        p.name = str("name")
        p.work = str("work")
        p.place = str("place")
        p.focus = (obj["focus"] as? [String] ?? []).filter { focusOptions.contains($0) }
        p.style = ["brief", "balanced", "detailed"].contains(str("style")) ? str("style") : ""
        p.notes = str("notes")
        p.facts = Learner.parse((obj["facts"] as? [String] ?? []).joined(separator: "\n"), known: [])
        return p
    }

    public static func refine(_ transcript: [(question: String, answer: String)], key: String, model: String) async -> Profile? {
        guard !key.isEmpty, !transcript.isEmpty else { return nil }
        let convo = transcript.map { "Jarvis: \($0.question)\nUser: \($0.answer.isEmpty ? "(no answer)" : $0.answer)" }.joined(separator: "\n")
        guard let r = try? await GeminiClient(apiKey: key).generate(
            model: model, system: extractInstructions, contents: [["role": "user", "parts": [["text": convo]]]],
            maxTokens: 500, thinking: model.hasPrefix("gemini-2") ? .budget(0) : .level("minimal")) else { return nil }
        return parseProfile(r.text)
    }
}
