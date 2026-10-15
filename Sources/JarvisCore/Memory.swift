import Foundation
import AppKit

public struct Automation: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var prompt: String
    public var hour: Int
    public var minute: Int
    public var days: [Int]   // Calendar weekdays, 1 = Sunday; empty means every day

    public init(id: String, prompt: String, hour: Int, minute: Int, days: [Int]) {
        self.id = id
        self.prompt = prompt
        self.hour = hour
        self.minute = minute
        self.days = days
    }

    public var label: String {
        let t = String(format: "%02d:%02d", hour, minute)
        return days.isEmpty ? "Daily \(t)" : "\(t) on \(days.map(String.init).joined(separator: ","))"
    }
}

/// One message in the conversation, kept so follow-ups make sense even after a restart.
public struct Turn: Codable, Equatable, Sendable {
    public var role: String      // user | assistant
    public var text: String
    public var at: Date
    public var mode: String?     // how the request was handled: local, chat, web, screen, hard
    public var source: String?

    public init(role: String, text: String, at: Date = Date(), mode: String? = nil, source: String? = nil) {
        self.role = role
        self.text = text
        self.at = at
        self.mode = mode
        self.source = source
    }
}

/// What Jarvis knows about the user, the recent conversation, and scheduled automations.
/// A small JSON file on this Mac, protected while the Mac is locked.
public final class MemoryStore: @unchecked Sendable {
    private struct Disk: Codable {
        var facts: [String] = []
        var automations: [Automation] = []
        var about: String = ""
        var turns: [Turn] = []

        init() {}
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            facts = try c.decodeIfPresent([String].self, forKey: .facts) ?? []
            automations = try c.decodeIfPresent([Automation].self, forKey: .automations) ?? []
            about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
            turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        }
    }

    private let lock = NSLock()
    private var disk = Disk()
    private let url: URL
    public var onChange: (@Sendable () -> Void)?
    public static let maxTurns = 60

    /// `directory` is for tests; the app keeps its memory in Application Support.
    public init(directory: URL? = nil) {
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Disk.self, from: data) { disk = d }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(disk) { try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }

    private func mutate(notify: Bool = true, _ f: (inout Disk) -> Void) {
        lock.lock()
        f(&disk)
        save()
        lock.unlock()
        if notify { onChange?() }
    }

    public var facts: [String] { lock.withLock { disk.facts } }
    public var automations: [Automation] { lock.withLock { disk.automations } }
    public var about: String { lock.withLock { disk.about } }
    public var turns: [Turn] { lock.withLock { disk.turns } }

    public func addFact(_ f: String) {
        let t = f.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        mutate {
            if !$0.facts.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { $0.facts.append(t) }
            if $0.facts.count > 80 { $0.facts.removeFirst() }
        }
    }
    public func removeFact(_ f: String) { mutate { $0.facts.removeAll { $0 == f } } }
    public func setAbout(_ text: String) { mutate { $0.about = text.trimmingCharacters(in: .whitespacesAndNewlines) } }

    public func addAutomation(_ a: Automation) { mutate { $0.automations.append(a) } }
    public func removeAutomation(_ id: String) { mutate { $0.automations.removeAll { $0.id == id } } }

    // MARK: Conversation

    public func append(_ turn: Turn) {
        mutate(notify: false) {
            $0.turns.append(turn)
            if $0.turns.count > Self.maxTurns { $0.turns.removeFirst($0.turns.count - Self.maxTurns) }
        }
    }

    public func clearConversation() { mutate(notify: false) { $0.turns.removeAll() } }

    /// The recent conversation to send with a request. A long pause starts a fresh topic,
    /// but the last exchange is always kept so "and tomorrow?" still makes sense.
    public func context(limit: Int = 10, now: Date = Date(), gap: TimeInterval = 6 * 3600) -> [Turn] {
        let all = turns
        guard let last = all.last else { return [] }
        if now.timeIntervalSince(last.at) > gap { return Array(all.suffix(2)) }
        var out: [Turn] = []
        for t in all.reversed() {
            if let prev = out.first, prev.at.timeIntervalSince(t.at) > gap { break }
            out.insert(t, at: 0)
            if out.count >= limit { break }
        }
        return out
    }

    /// Everything the model should know about the user, for its instructions.
    public func profile(name: String) -> String {
        var parts: [String] = []
        if !name.isEmpty { parts.append("The user's name is \(name).") }
        let a = about
        if !a.isEmpty { parts.append("About the user, in their words: \(a)") }
        let f = facts
        if !f.isEmpty { parts.append("Things you know about the user:\n" + f.map { "- \($0)" }.joined(separator: "\n")) }
        return parts.joined(separator: "\n")
    }
}

/// Keeps a single timer pointed at the next automation, so nothing polls while idle.
@MainActor
public final class Scheduler {
    private var timer: Timer?
    private let memory: MemoryStore
    public var onFire: ((Automation) -> Void)?

    public init(memory: MemoryStore) {
        self.memory = memory
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reschedule() }
        }
    }

    nonisolated public static func nextFire(_ a: Automation, after now: Date) -> Date? {
        let cal = Calendar.current
        let days = a.days.isEmpty ? [nil] : a.days.map { Optional($0) }
        return days.compactMap { wd -> Date? in
            var c = DateComponents(hour: a.hour, minute: a.minute, second: 0)
            c.weekday = wd
            return cal.nextDate(after: now, matching: c, matchingPolicy: .nextTime)
        }.min()
    }

    public func reschedule() {
        timer?.invalidate()
        let now = Date()
        let upcoming = memory.automations.compactMap { a in Self.nextFire(a, after: now).map { (a, $0) } }
        guard let next = upcoming.min(by: { $0.1 < $1.1 }) else { return }
        timer = Timer.scheduledTimer(withTimeInterval: max(1, next.1.timeIntervalSinceNow), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for (a, d) in upcoming where abs(d.timeIntervalSince(next.1)) < 1 { self.onFire?(a) }
                self.reschedule()
            }
        }
    }
}
