import Foundation

/// Google's free tier gives each model its own small allowance per minute and per day, and some models
/// (often the Pro previews) none at all. This keeps track of which models said no, and until when, so
/// Jarvis stops asking them and moves to one that still has room.
public final class QuotaBook: @unchecked Sendable {
    public static let shared = QuotaBook()

    public enum Kind: String, Codable, Sendable { case perMinute, perDay, noFreeTier, unknown }

    public struct Refusal: Sendable, Equatable {
        public let kind: Kind
        public let retryAfter: TimeInterval?
    }

    private let lock = NSLock()
    private var blocked: [String: (until: Date, kind: Kind)] = [:]
    /// Google's own words for the last refusal of each model, for Settings.
    private var said: [String: String] = [:]
    private let key = "jarvis.quota.blocked"

    init() {
        if let saved = UserDefaults.standard.dictionary(forKey: key) as? [String: [String: Any]] {
            for (m, v) in saved {
                if let t = v["until"] as? Double, let k = (v["kind"] as? String).flatMap(Kind.init(rawValue:)), t > Date().timeIntervalSince1970 {
                    blocked[m] = (Date(timeIntervalSince1970: t), k)
                }
            }
        }
    }

    private func save() {
        let out = blocked.mapValues { ["until": $0.until.timeIntervalSince1970, "kind": $0.kind.rawValue] as [String: Any] }
        UserDefaults.standard.set(out, forKey: key)
    }

    /// Reads a 429 body: which limit was hit, and how long Google asks us to wait.
    public static func parse(_ body: String) -> Refusal {
        let lower = body.lowercased()
        var retry: TimeInterval?
        if let r = body.range(of: #""retryDelay"\s*:\s*"([0-9.]+)s""#, options: .regularExpression) {
            retry = Double(body[r].filter { $0.isNumber || $0 == "." })
        } else if let r = lower.range(of: #"retry in ([0-9.]+)\s*s"#, options: .regularExpression) {
            retry = Double(lower[r].filter { $0.isNumber || $0 == "." })
        }
        if lower.contains("limit: 0") || lower.contains(#""quotavalue": "0""#) || lower.contains("not available on the free tier") || lower.contains("free tier is not") {
            return Refusal(kind: .noFreeTier, retryAfter: nil)
        }
        if lower.contains("perday") || lower.contains("per day") || lower.contains("requestsperday") || lower.contains("daily") {
            return Refusal(kind: .perDay, retryAfter: retry)
        }
        if lower.contains("perminute") || lower.contains("per minute") || retry != nil {
            return Refusal(kind: .perMinute, retryAfter: retry ?? 30)
        }
        return Refusal(kind: .unknown, retryAfter: retry)
    }

    /// Free-tier daily limits reset at midnight Pacific time.
    public static func nextPacificMidnight(after now: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Los_Angeles") ?? .current
        return cal.nextDate(after: now, matching: DateComponents(hour: 0, minute: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(86_400)
    }

    @discardableResult
    public func note(_ model: String, body: String, now: Date = Date()) -> Refusal {
        let r = Self.parse(body)
        let until: Date
        switch r.kind {
        case .perMinute: until = now.addingTimeInterval(max(5, r.retryAfter ?? 30))
        case .perDay: until = Self.nextPacificMidnight(after: now)
        case .noFreeTier: until = now.addingTimeInterval(7 * 86_400)
        case .unknown: until = now.addingTimeInterval(max(10, r.retryAfter ?? (model.hasSuffix("+search") ? 20 * 60 : 30)))
        }
        let message = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
            .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? String(body.prefix(200))
        lock.withLock {
            blocked[model] = (until, r.kind)
            said[model] = Redact.secrets(String(message.prefix(240)))
            save()
        }
        return r
    }

    public func usable(_ model: String, now: Date = Date()) -> Bool {
        lock.withLock {
            guard let b = blocked[model] else { return true }
            if b.until <= now { blocked[model] = nil; save(); return true }
            return false
        }
    }

    public func reason(_ model: String) -> (kind: Kind, until: Date)? {
        lock.withLock { blocked[model].flatMap { $0.until > Date() ? ($0.kind, $0.until) : nil } }
    }

    public func clear() { lock.withLock { blocked.removeAll(); save() } }

    /// Lines for Settings, one per model that's resting.
    public func status() -> [String] {
        lock.withLock {
            blocked.filter { $0.value.until > Date() }.sorted { $0.key < $1.key }.map { m, b in
                Self.describe(m, b.kind, b.until) + (said[m].map { "\nGoogle said: \($0)" } ?? "")
            }
        }
    }

    public static func describe(_ model: String, _ kind: Kind, _ until: Date) -> String {
        let t = until.formatted(date: .omitted, time: .shortened)
        switch kind {
        case .perMinute: return "\(model): too many requests this minute, free again at \(t)."
        case .perDay: return "\(model): today's free requests are used up; they reset at \(t) (midnight in California)."
        case .noFreeTier: return "\(model): not included in Gemini's free tier on this key."
        case .unknown: return "\(model): Google asked Jarvis to slow down until \(t)."
        }
    }
}
