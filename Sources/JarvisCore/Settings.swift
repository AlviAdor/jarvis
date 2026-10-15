import Foundation

public struct JarvisSettings: Codable, Equatable {
    public var userName = ""
    // Models
    public var modelChoice = "auto"   // auto | lite | flash | pro
    public var liteModel = "gemini-2.5-flash-lite"
    public var flashModel = "gemini-2.5-flash"
    public var proModel = "gemini-2.5-pro"
    public var claudeEnabled = true   // used first when a key is set; Gemini takes over on failure
    public var claudeLiteModel = "claude-haiku-5-5"
    public var claudeFlashModel = "claude-sonnet-5-5"
    public var claudeProModel = "claude-opus-5-5"
    public var dailyRequestCap = 500
    public var maxSteps = 25
    // Voice
    public var wakeWordEnabled = true
    public var wakeWord = "jarvis"
    public var micThreshold = 0.02
    public var speakReplies = true
    public var voiceRate = 0.5
    public var launchAtLogin = false
    // Tools and safety
    public var confirmRisky = true
    public var shellEnabled = true
    public var mailEnabled = true
    public var searchEnabled = true
    public var allowedFolders = ["~/Documents", "~/Desktop", "~/Downloads"]
    // Look
    public var accent = "cyan"
    public var reduceMotion = false
    public var overlayEnabled = true

    public init() {}

    public func claudeModelID(_ t: Tier) -> String {
        switch t {
        case .lite: return claudeLiteModel
        case .flash: return claudeFlashModel
        case .pro: return claudeProModel
        }
    }

    public func modelID(_ t: Tier) -> String {
        switch t {
        case .lite: return liteModel
        case .flash: return flashModel
        case .pro: return proModel
        }
    }
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
    @Published public var geminiKey: String {
        didSet { Keychain.set(geminiKey, for: "google") }
    }

    @Published public var claudeKey: String {
        didSet { Keychain.set(claudeKey, for: "anthropic") }
    }

    public init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let s = try? JSONDecoder().decode(JarvisSettings.self, from: data) {
            value = s
        } else {
            value = JarvisSettings()
        }
        geminiKey = Keychain.get("google") ?? ""
        claudeKey = Keychain.get("anthropic") ?? ""
    }
}
