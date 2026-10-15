import Foundation

public struct JarvisSettings: Codable, Equatable {
    public var modelChoice = "auto"
    public var geminiFastModel = "gemini-2.5-flash"
    public var geminiProModel = "gemini-2.5-pro"
    public var preferFreeTier = true
    public var monthlyBudgetUSD = 20.0
    public var taskBudgetUSD = 0.75
    public var maxSteps = 25
    public var confirmRisky = true
    public var speakReplies = true
    public var voiceRate = 0.5
    public var accent = "cyan"
    public var reduceMotion = false

    public init() {}
}

@MainActor
public final class SettingsStore: ObservableObject {
    private static let defaultsKey = "jarvis.settings"

    @Published public var value: JarvisSettings {
        didSet {
            if let data = try? JSONEncoder().encode(value) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }
    @Published public var claudeKey: String {
        didSet { Keychain.set(claudeKey, for: "anthropic") }
    }
    @Published public var geminiKey: String {
        didSet { Keychain.set(geminiKey, for: "google") }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let s = try? JSONDecoder().decode(JarvisSettings.self, from: data) {
            value = s
        } else {
            value = JarvisSettings()
        }
        claudeKey = Keychain.get("anthropic") ?? ""
        geminiKey = Keychain.get("google") ?? ""
    }
}

@MainActor
public final class CostTracker: ObservableObject {
    @Published public private(set) var month = 0.0
    @Published public private(set) var task = 0.0

    private var key: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM"
        return "jarvis.spend." + f.string(from: Date())
    }

    public init() {
        month = UserDefaults.standard.double(forKey: key)
    }

    public func startTask() { task = 0 }

    public func add(_ spec: ModelSpec, _ usage: Usage) {
        let c = spec.cost(usage)
        task += c
        month += c
        UserDefaults.standard.set(month, forKey: key)
    }
}
