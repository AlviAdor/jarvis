import Foundation

public struct JarvisSettings: Codable, Equatable {
    /// Bumped when a default changes in a way saved settings should pick up once.
    public var settingsVersion = 3
    public var userName = ""
    public var answerStyle = "brief"     // brief | balanced | detailed
    // About you, so answers fit your life
    public var aboutWork = ""
    public var aboutPlace = ""
    public var aboutFocus: [String] = []
    public var aboutNotes = ""
    // Models
    public var modelChoice = "auto"   // auto | lite | flash | pro
    public var liteModel = "gemini-3.5-flash-lite"
    public var flashModel = "gemini-3.8-flash"
    public var proModel = "gemini-3.1-pro-preview"
    public var claudeEnabled = true   // used first when a key is set; Gemini takes over on failure
    public var claudeLiteModel = "claude-haiku-5-5"
    public var claudeFlashModel = "claude-sonnet-5-5"
    public var claudeProModel = "claude-opus-5-5"
    public var dailyRequestCap = 500
    public var knownModels: [String] = []   // what this key can use, from Google's model list
    public var maxSteps = 25
    // Local model for quick answers
    public var localEngine = "auto"    // auto | apple | ollama | off
    public var ollamaModel = ""        // empty = smallest installed
    public var mcpServers: [MCPServerConfig] = []
    // Voice
    public var wakeWordEnabled = true
    public var wakeWord = "jarvis"
    public var micThreshold = 0.02
    public var speakReplies = true
    public var responsePause = 1.4     // seconds of silence that end what you're saying
    public var bargeIn = true          // talking over Jarvis stops it
    public var hotkey = "option+space" // option+space | control+space | command+shift+j | off
    public var voiceEngine = "apple"   // apple (on this Mac) | gemini (studio voices, online)
    public var geminiVoice = "Charon"
    public var voiceStyle = "Calm, confident and warm, like a refined British butler"
    public var ttsModel = "gemini-3.8-flash-lite-tts"
    public var voiceID = ""            // empty = best available system voice
    public var voiceRate = 0.5
    public var voicePitch = 1.0
    public var voiceVolume = 1.0
    public var voiceLockEnabled = false
    public var voiceLockStrictness = 0.5
    // Behaviour
    public var narrateActions = true
    public var stepByStep = false
    public var showHighlights = true
    public var confirmRisky = true
    public var shellEnabled = true
    public var mailEnabled = true
    public var searchEnabled = true
    public var allowedFolders = ["~/Documents", "~/Desktop", "~/Downloads"]
    public var calendarEnabled = true
    public var contactsEnabled = true
    public var notesEnabled = true
    public var messagesEnabled = true
    public var controlEnabled = true     // media keys, volume, appearance, Wi-Fi
    public var cleanupEnabled = true     // disk cleanup and folder organising
    public var shortcutsEnabled = true
    public var webReadEnabled = true     // reading web pages
    // Mac care
    public var healthAlerts = true
    public var showTelemetry = false     // live readings are opt-in; the main window stays clean
    // Memory
    public var rememberConversations = true   // keep the conversation across launches
    public var learnAboutMe = true            // note lasting facts about the user from conversations
    // App
    public var showInDock = true
    public var openWindowAtLaunch = true
    public var launchAtLogin = false
    public var overlayEnabled = true
    public var quickPanel = true         // the shortcut opens a floating ask bar
    public var keepHistory = true        // show earlier answers from this session
    // Look
    public var orbStyle = "sphere"       // sphere | nucleus
    public var colorMode = "adaptive"    // adaptive: shifts from the light to the heavy colour as work gets harder | fixed
    public var heavyAccentHex = "#FF3B3B"
    public var accentHex = "#3DD6F5"
    public var theme = "dark"          // dark | light | system
    public var reduceMotion = false
    public var userDetails = false     // show diagnostics

    public init() {}

    /// The "About you" answers as one paragraph for the model.
    public var aboutText: String {
        var parts: [String] = []
        if !aboutWork.isEmpty { parts.append("Does: \(aboutWork).") }
        if !aboutPlace.isEmpty { parts.append("Based in \(aboutPlace).") }
        if !aboutFocus.isEmpty { parts.append("Mostly wants help with: \(aboutFocus.joined(separator: ", ")).") }
        if !aboutNotes.isEmpty { parts.append(aboutNotes) }
        return parts.joined(separator: " ")
    }

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

    /// Saved settings laid over today's defaults, so new options never reset old choices.
    static func load(from data: Data?) -> JarvisSettings {
        let defaults = JarvisSettings()
        guard let data,
              let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = (try? JSONEncoder().encode(defaults)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        else { return defaults }
        var merged = base
        for (k, v) in saved where base[k] != nil { merged[k] = v }
        guard let bytes = try? JSONSerialization.data(withJSONObject: merged),
              var s = try? JSONDecoder().decode(JarvisSettings.self, from: bytes) else { return defaults }
        // Version 2: live Mac readings became opt-in.
        let version = saved["settingsVersion"] as? Int ?? 1
        if version < 2 { s.showTelemetry = false }
        // Version 3: give people more time to finish a sentence.
        if version < 3, s.responsePause < 1.4 { s.responsePause = 1.4 }
        s.settingsVersion = defaults.settingsVersion
        // Gemini 2.x isn't offered to new accounts any more.
        if s.liteModel.hasPrefix("gemini-2") { s.liteModel = defaults.liteModel }
        if s.flashModel.hasPrefix("gemini-2") { s.flashModel = defaults.flashModel }
        if s.proModel.hasPrefix("gemini-2") { s.proModel = defaults.proModel }
        return s
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
    @Published public var geminiKey = "" {
        didSet { persist("google", geminiKey) }
    }
    @Published public var claudeKey = "" {
        didSet { persist("anthropic", claudeKey) }
    }
    @Published public private(set) var keysLoaded = false

    private var loading = true
    private var pending: [String: Task<Void, Never>] = [:]

    public init() {
        value = JarvisSettings.load(from: UserDefaults.standard.data(forKey: Self.defaultsKey))
        // After an update macOS may ask before letting Jarvis read its saved keys.
        // Read them off the main thread so the window never freezes behind that prompt.
        Task.detached(priority: .userInitiated) {
            let g = Keychain.get("google") ?? ""
            let c = Keychain.get("anthropic") ?? ""
            await self.finishLoading(gemini: g, claude: c)
        }
    }

    private func finishLoading(gemini: String, claude: String) {
        geminiKey = gemini
        claudeKey = claude
        loading = false
        keysLoaded = true
    }

    /// Saves shortly after typing stops, off the main thread, instead of on every keystroke.
    private func persist(_ account: String, _ key: String) {
        guard !loading else { return }
        pending[account]?.cancel()
        pending[account] = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: account)
        }
    }
}
