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

/// Facts the user asked Jarvis to remember, and scheduled automations. Small JSON file on disk.
public final class MemoryStore: @unchecked Sendable {
    private struct Disk: Codable {
        var facts: [String] = []
        var automations: [Automation] = []
    }

    private let lock = NSLock()
    private var disk = Disk()
    private let url: URL
    public var onChange: (@Sendable () -> Void)?

    public init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: url), let d = try? JSONDecoder().decode(Disk.self, from: data) { disk = d }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(disk) { try? data.write(to: url, options: .atomic) }
    }

    private func mutate(_ f: (inout Disk) -> Void) {
        lock.lock()
        f(&disk)
        save()
        lock.unlock()
        onChange?()
    }

    public var facts: [String] { lock.lock(); defer { lock.unlock() }; return disk.facts }
    public var automations: [Automation] { lock.lock(); defer { lock.unlock() }; return disk.automations }

    public func addFact(_ f: String) {
        mutate { if !$0.facts.contains(f) { $0.facts.append(f) }; if $0.facts.count > 60 { $0.facts.removeFirst() } }
    }
    public func removeFact(_ f: String) { mutate { $0.facts.removeAll { $0 == f } } }

    public func addAutomation(_ a: Automation) { mutate { $0.automations.append(a) } }
    public func removeAutomation(_ id: String) { mutate { $0.automations.removeAll { $0.id == id } } }
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
