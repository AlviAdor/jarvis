import Foundation

// MARK: Errors

/// What kind of failure happened, so Jarvis can pick the right way to recover instead of giving up.
public enum ErrorKind: String, Codable, Sendable {
    case quota, auth, modelMissing, network, timeout, refused, permission, badRequest, server, other

    public static func of(_ error: Error) -> ErrorKind {
        if let e = error as? LLMError {
            switch e {
            case .missingKey: return .auth
            case .refused: return .refused
            case .other: return .permission
            case .badResponse: return .server
            case .http(let code, _):
                switch code {
                case 429: return .quota
                case 401, 402, 403: return .auth
                case 404: return .modelMissing
                case 400: return .badRequest
                case 408, 504: return .timeout
                case 500...599: return .server
                default: return .other
                }
            }
        }
        if let u = error as? URLError {
            switch u.code {
            case .timedOut: return .timeout
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return .network
            default: return .network
            }
        }
        return .other
    }
}

public enum Recovery: Equatable, Sendable {
    /// Wait briefly and try the same thing again.
    case retry(after: TimeInterval)
    /// Move on to the next model in the chain.
    case nextModel
    /// The cloud can't help right now: answer on this Mac if possible.
    case local
    /// Only the user can fix this; say exactly what to do.
    case tellUser(String)

    public static func plan(_ kind: ErrorKind, attempt: Int) -> Recovery {
        switch kind {
        case .network: return attempt == 0 ? .retry(after: 1.5) : .local
        case .timeout, .server: return attempt == 0 ? .retry(after: 1) : .nextModel
        case .quota, .modelMissing, .badRequest: return .nextModel
        case .refused: return .tellUser("The model declined that request. Try rephrasing it.")
        case .auth: return .tellUser("Your API key was refused. Open Settings, Keys and press Test to check it.")
        case .permission: return .tellUser("macOS is blocking a permission Jarvis needs. Open Settings, Safety to allow it.")
        case .other: return attempt == 0 ? .retry(after: 1) : .local
        }
    }
}

// MARK: Experience

/// One finished task, kept on this Mac so Jarvis can learn what works.
public struct Episode: Codable, Equatable, Sendable {
    public var date: Date
    public var task: String
    public var mode: String
    public var provider: String
    public var success: Bool
    public var verified: Bool?      // nil when there was nothing to check
    public var error: ErrorKind?
    public var steps: Int
    public var seconds: Double

    public init(date: Date, task: String, mode: String, provider: String, success: Bool, verified: Bool?,
                error: ErrorKind?, steps: Int, seconds: Double) {
        self.date = date
        self.task = task
        self.mode = mode
        self.provider = provider
        self.success = success
        self.verified = verified
        self.error = error
        self.steps = steps
        self.seconds = seconds
    }
}

/// A short, reusable rule learned from a past task, such as what fixed a failure.
public struct Lesson: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var text: String
    public var keywords: [String]
    public var learned: Date
    public var uses: Int
}

/// Remembers outcomes and lessons across launches, and hands relevant lessons back to future tasks.
public final class ExperienceLog: @unchecked Sendable {
    private struct Disk: Codable {
        var episodes: [Episode] = []
        var lessons: [Lesson] = []
        var modelFailures: [String: [Date]] = [:]
    }

    private let lock = NSLock()
    private var disk = Disk()
    private let url: URL?
    public var onChange: (@Sendable () -> Void)?

    /// Pass nil to keep everything in memory (tests).
    public init(file: URL? = ExperienceLog.defaultURL) {
        url = file
        if let file, let data = try? Data(contentsOf: file), let d = try? JSONDecoder().decode(Disk.self, from: data) { disk = d }
    }

    public static var defaultURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("experience.json")
    }

    private func mutate(_ f: (inout Disk) -> Void) {
        lock.withLock {
            f(&disk)
            if let url, let data = try? JSONEncoder().encode(disk) { try? data.write(to: url, options: .atomic) }
        }
        onChange?()
    }

    public var episodes: [Episode] { lock.withLock { disk.episodes } }
    public var lessons: [Lesson] { lock.withLock { disk.lessons } }

    public func record(_ e: Episode) {
        mutate { d in
            d.episodes.append(e)
            if d.episodes.count > 300 { d.episodes.removeFirst(d.episodes.count - 300) }
        }
    }

    // MARK: Lessons

    static let stop: Set<String> = ["the", "and", "for", "with", "that", "this", "what", "can", "you", "please", "jarvis",
                                    "into", "from", "your", "have", "will", "just", "then", "them", "about", "make", "want"]

    public static func keywords(_ s: String) -> [String] {
        let words = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 && !stop.contains($0) }
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    /// Adds a lesson, or refreshes one that says nearly the same thing.
    public func learn(_ text: String, about task: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10, t.count <= 300 else { return }
        let kw = Self.keywords(task)
        mutate { d in
            let lower = t.lowercased()
            if let i = d.lessons.firstIndex(where: { $0.text.lowercased() == lower }) {
                d.lessons[i].learned = Date()
                d.lessons[i].keywords = Array(Set(d.lessons[i].keywords + kw)).sorted()
                return
            }
            d.lessons.append(Lesson(id: String(UUID().uuidString.prefix(8)), text: t, keywords: kw, learned: Date(), uses: 0))
            if d.lessons.count > 80 {
                // Drop the least useful, oldest lesson first.
                if let worst = d.lessons.indices.min(by: { (d.lessons[$0].uses, d.lessons[$0].learned) < (d.lessons[$1].uses, d.lessons[$1].learned) }) {
                    d.lessons.remove(at: worst)
                }
            }
        }
    }

    /// The few lessons that share the most words with this task.
    public func relevant(to task: String, limit: Int = 4) -> [Lesson] {
        let kw = Set(Self.keywords(task))
        guard !kw.isEmpty else { return [] }
        let all = lock.withLock { disk.lessons }
        var scored: [(lesson: Lesson, score: Int)] = []
        for l in all {
            let score = Set(l.keywords).intersection(kw).count
            if score >= 1 { scored.append((l, score)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.lesson.learned > b.lesson.learned }
        let picked: [Lesson] = scored.prefix(limit).map { $0.lesson }
        if !picked.isEmpty {
            let ids = Set(picked.map(\.id))
            mutate { d in for i in d.lessons.indices where ids.contains(d.lessons[i].id) { d.lessons[i].uses += 1 } }
        }
        return picked
    }

    public func forget(_ id: String) { mutate { $0.lessons.removeAll { $0.id == id } } }
    public func forgetAll() { mutate { $0 = Disk() } }

    // MARK: Model health

    public func noteFailure(model: String) {
        mutate { d in
            var list = d.modelFailures[model, default: []].filter { Date().timeIntervalSince($0) < 3600 }
            list.append(Date())
            d.modelFailures[model] = list
        }
    }

    /// Models that failed several times in the last hour go to the back of the line.
    public func reorder(_ chain: [String]) -> [String] {
        let failures = lock.withLock { disk.modelFailures }
        func recent(_ m: String) -> Int { failures[m]?.filter { Date().timeIntervalSince($0) < 3600 }.count ?? 0 }
        let healthy = chain.filter { recent($0) < 3 }
        let tired = chain.filter { recent($0) >= 3 }
        return healthy + tired
    }

    // MARK: Summary

    public struct Stats: Sendable {
        public let tasks: Int
        public let succeeded: Int
        public let verified: Int
        public let checked: Int
    }

    public var stats: Stats {
        let e = episodes.suffix(100)
        return Stats(tasks: e.count, succeeded: e.filter(\.success).count,
                     verified: e.filter { $0.verified == true }.count, checked: e.filter { $0.verified != nil }.count)
    }

    /// Context added to the system prompt so past lessons shape this task.
    public func context(for task: String) -> String {
        let l = relevant(to: task)
        guard !l.isEmpty else { return "" }
        return "Lessons from your past tasks on this Mac (follow them when they apply):\n" + l.map { "- \($0.text)" }.joined(separator: "\n")
    }
}

// MARK: Verification

/// An independent check that a task really got done, so "Done" is never just the model's word for it.
public enum Verifier {
    public struct Verdict: Equatable, Sendable {
        public let done: Bool
        public let reason: String
        public let lesson: String?
    }

    public static let instructions = """
    You check whether an assistant really finished a task on the user's Mac. You are given the task, \
    the steps it took with their results (including command output and errors), its final claim, and, for screen tasks, \
    a screenshot taken just now plus a list of what is on screen.
    Judge only from that evidence. Error messages, failed commands, a screen that doesn't show the result, \
    or a claim with no supporting step mean it is NOT done. Don't demand proof that is impossible to show; \
    a successful command or a visible result is enough.
    Reply with JSON only: {"done": true or false, "reason": "one short sentence", "lesson": "a short reusable rule for next time, or empty"}.
    Write a lesson only when something failed or needed a workaround, phrased as general advice.
    """

    /// Reads the checker's reply. Anything unreadable counts as unverified rather than as success.
    public static func parse(_ text: String) -> Verdict {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = t.firstIndex(of: "{"), let e = t.lastIndex(of: "}"), s < e { t = String(t[s...e]) }
        guard let data = t.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let lower = text.lowercased()
            if lower.contains("\"done\": true") || lower.hasPrefix("yes") { return Verdict(done: true, reason: "", lesson: nil) }
            return Verdict(done: false, reason: "The check couldn't be read.", lesson: nil)
        }
        let done = (obj["done"] as? Bool) ?? ((obj["done"] as? String)?.lowercased() == "true")
        let reason = (obj["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let lesson = (obj["lesson"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Verdict(done: done, reason: reason, lesson: (lesson?.isEmpty ?? true) ? nil : lesson)
    }

    /// Only work that changed something needs checking; plain answers and lookups don't.
    public static func needsCheck(mode: Mode, stepTitles: [String]) -> Bool {
        if mode == .screen { return true }
        let acting = ["Running", "Opening", "Typing", "Clicking", "Writing", "Saving", "Sending", "Creating", "Moving",
                      "Deleting", "Installing", "Filling", "Changing", "Setting", "Copying", "Pressing", "Using", "Zipping",
                      "Unzipping", "Switching", "Spotify", "Scheduling", "Quitting", "Messaging", "Making", "Git", "Cleaning",
                      "Drafting", "Cancelling"]
        return stepTitles.contains { t in acting.contains { t.hasPrefix($0) } }
    }

    public static func check(task: String, claim: String, steps: [(title: String, detail: String?, failed: Bool)],
                             screenshot: Shot?, screenMap: String?, key: String, models: [String]) async -> Verdict? {
        guard !key.isEmpty else { return nil }
        var log = steps.suffix(25).enumerated().map { i, s in
            "\(i + 1). \(s.failed ? "[FAILED] " : "")\(s.title)" + (s.detail.map { "\n   " + $0.prefix(600).replacingOccurrences(of: "\n", with: "\n   ") } ?? "")
        }.joined(separator: "\n")
        if log.isEmpty { log = "(no steps recorded)" }
        var parts: [[String: Any]] = [["text": "Task: \(task)\n\nSteps taken:\n\(log)\n\nAssistant's final claim: \(claim)" + (screenMap ?? "")]]
        if let shot = screenshot { parts.append(GeminiClient.imagePart(shot.jpeg)) }
        let client = GeminiClient(apiKey: key)
        for model in models {
            if let r = try? await client.generate(model: model, system: instructions, contents: [["role": "user", "parts": parts]],
                                                  maxTokens: 200, thinking: model.hasPrefix("gemini-2") ? .budget(0) : .level("low")) {
                return parse(r.text)
            }
        }
        return nil
    }
}
