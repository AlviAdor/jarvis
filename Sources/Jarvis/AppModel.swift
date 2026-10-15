import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications
import JarvisCore

enum Phase: String {
    case idle, listening, thinking, acting, speaking
}

struct Step: Identifiable, Equatable {
    let id: UUID
    var title: String
    var detail: String?
    var state: ActionEvent.State
    var icon: String?
}

struct Highlight: Equatable {
    let id = UUID()
    let point: CGPoint
    let title: String
}

/// One question and its answer, kept for this session only.
struct Exchange: Identifiable, Equatable {
    let id = UUID()
    let question: String
    let answer: String
    let source: String
    let at: Date
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = SettingsStore()
    let usage = UsageTracker()
    let voice = VoiceEngine()
    let memory = MemoryStore()
    let speaker = Speaker()
    let telemetry = Telemetry()
    private lazy var scheduler = Scheduler(memory: memory)
    private let router = Router()
    private let hotKey = HotKey()

    // What the user sees: the question, the answer, and the steps taken. Nothing else.
    @Published var phase: Phase = .idle { didSet { refreshOverlay() } }
    @Published var question = ""
    @Published var answer = ""
    @Published var answerSource = ""
    @Published var steps: [Step] = []
    @Published var history: [Exchange] = []
    @Published var notice: String?
    /// A button on the notice, such as Undo.
    @Published var noticeAction: String?
    private var noticeHandler: (() -> Void)?
    /// The pointer is over the floating bubble, so it stays put.
    @Published var overlayHovered = false { didSet { if !overlayHovered { refreshOverlay() } else { hideTask?.cancel() } } }
    @Published var typed = ""
    @Published var highlight: Highlight?
    @Published var overlayVisible = false
    @Published var overlayText = ""
    /// The floating ask bar is open for typing (opened with the shortcut).
    @Published var quickActive = false
    @Published var diagnostics: [String] = []
    /// False while the main window is hidden or covered, so its animations and telemetry stop.
    @Published var windowVisible = true { didSet { telemetry.setActive(wantsTelemetry) } }

    // Setup and settings
    @Published var termsAccepted: Bool
    @Published var onboarded: Bool
    @Published var availableModels: [String] = []
    @Published var ollamaModels: [String] = []
    @Published var facts: [String] = []
    @Published var automations: [Automation] = []
    @Published var geminiTest: [TestLine] = []
    @Published var claudeTest: [TestLine] = []
    @Published var localTest: [TestLine] = []
    @Published var testing = false
    @Published var voices: [VoiceOption] = []
    @Published var permissions: [PermissionItem] = []
    @Published var about = ""
    // The composer: files waiting to be sent, and tools switched on for the next requests.
    @Published var attachments: [Attachment] = []
    @Published var searchOn = false
    @Published var thinkOn = false
    @Published var screenOn = false
    /// The answer as the model wrote it, with code blocks and lists, for display.
    @Published var answerMarkdown = ""
    private var lastAttachments: [Attachment] = []
    /// Post the answer as a notification (automations that run while you're elsewhere).
    private var notifyAnswer = false
    /// True while Jarvis is talking.
    @Published private(set) var speaking = false
    /// Where the setup guide opens: returning users skip what they've already done.
    var onboardingStart = 0
    /// 0 for light work, 1 for heavy work; drives the adaptive colour.
    @Published var workload: Double = 0
    // Ollama setup
    @Published var ollamaBusy: String?
    @Published var pullProgress: Double?

    var openMainWindow: (() -> Void)?
    private var lastLearn = Date.distantPast
    private var voiceFallbackNoted = Date.distantPast
    private var voicesOffered = Set<String>()
    private var lastWarm = Date.distantPast
    private var systemStrained = false
    private var job: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var highlightTask: Task<Void, Never>?
    private var healthTimer: Timer?
    private var lastAlerts: [String: Date] = [:]
    private var extremeSince: [SystemMonitor.Alert.Kind: Date] = [:]
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var dockShown: Bool?
    private var claudeBlockedUntil = Date.distantPast
    private var hudWasVisible = false

    var needsOnboarding: Bool { !termsAccepted || !onboarded }
    var still: Bool { store.value.reduceMotion || !windowVisible }
    var busy: Bool { phase == .thinking || phase == .acting }
    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }
    private var wantsTelemetry: Bool { store.value.showTelemetry && (windowVisible || quickActive) && !needsOnboarding }
    /// How hard Jarvis (or the Mac) is working right now, 0 to 1. Drives the orb's speed and the colour.
    var intensity: Double { max(workload, systemStrained ? 0.85 : 0) }

    /// The light colour while work is easy, shifting towards the heavy colour as it gets harder.
    var accent: Color {
        let s = store.value
        guard s.colorMode == "adaptive" else { return Color(hex: s.accentHex) }
        return Color.blend(Color(hex: s.accentHex), Color(hex: s.heavyAccentHex), max(workload, systemStrained ? 0.85 : 0))
    }
    var colorScheme: ColorScheme? {
        switch store.value.theme {
        case "light": return .light
        case "system": return nil
        default: return .dark
        }
    }

    private init() {
        termsAccepted = UserDefaults.standard.string(forKey: "jarvis.terms.version") == Terms.version
        // Version 3 of the guide added the spoken getting-to-know-you chat; earlier users see that part once.
        onboarded = UserDefaults.standard.integer(forKey: "jarvis.onboarding.version") >= 3
        if termsAccepted { onboardingStart = 2 }

        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        telemetry.$snapshot.compactMap { $0 }.sink { [weak self] snap in self?.noteStrain(snap) }.store(in: &bag)
        voice.$armed.sink { [weak self] armed in
            guard let self else { return }
            if armed, self.phase == .idle || self.phase == .speaking {
                self.phase = .listening
                NSSound(named: "Tink")?.play()
            }
            if !armed, self.phase == .listening { self.phase = .idle }
        }.store(in: &bag)
        voice.$partial.sink { [weak self] p in if !p.isEmpty { self?.overlayText = p } }.store(in: &bag)
        store.$value.dropFirst().sink { [weak self] _ in Task { @MainActor in self?.applySettings() } }.store(in: &bag)
        $quickActive.dropFirst().sink { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.telemetry.setActive(self.wantsTelemetry) }
        }.store(in: &bag)

        voice.onCommand = { [weak self] text in self?.heard(text) }
        // Warm the on-device model only once the speech is for Jarvis, not for every sound in the room.
        voice.onWakeHeard = { [weak self] in
            guard let self else { return }
            LocalBrain.shared.prewarm(self.store.value)
            self.warmCloud()
        }
        voice.onRejected = { [weak self] heard, vector in
            guard let self else { return }
            let match = self.voice.lastMatch.map { String(format: " (match %.0f%%, needs %.0f%%)", $0.score * 100, $0.needed * 100) } ?? ""
            self.log("Voice didn't match" + match)
            self.flash("That didn't sound like you, so I ignored it.", action: "It was me") { [weak self] in
                guard let self else { return }
                self.voice.confirmMine(vector)
                let command = self.voice.command(in: heard)
                if command.count >= 2 { self.submit(command) } else { self.pushToTalk() }
            }
        }
        // Say just "Jarvis" and it answers by name before listening.
        voice.onWakeOnly = { [weak self] in
            guard let self, self.store.value.answerWhenCalled, self.store.value.speakReplies else { return }
            self.speaker.say(self.acknowledgement(), settings: self.store.value, queue: false)
        }
        // Talking over Jarvis stops it, and what you say becomes the next request.
        voice.onBargeIn = { [weak self] in
            guard let self, self.speaking else { return }
            self.speaker.stop()
            // The setup chat captures the answer itself; mid-task, talking only quiets Jarvis.
            guard !self.needsOnboarding, !self.busy else { return }
            self.voice.arm()   // not a push-to-talk arm, so "only my voice" still applies
            self.phase = .listening
        }
        voice.onEnrolled = { [weak self] ok in
            guard let self else { return }
            if ok { self.store.value.voiceLockEnabled = true }
            let msg = ok ? "Got it. I'll recognise your voice now." : "I couldn't learn your voice. Please try again somewhere quiet."
            self.flash(msg)
            self.speaker.say(msg, settings: self.store.value)
        }
        speaker.geminiKey = { [weak self] in self?.store.geminiKey ?? "" }
        speaker.onSpeakingChange = { [weak self] speaking in
            guard let self else { return }
            self.speaking = speaking
            self.voice.suspended = speaking
            if speaking, self.phase == .idle { self.phase = .speaking }
            if !speaking, self.phase == .speaking { self.phase = .idle }
        }
        speaker.knownModels = { [weak self] in self?.store.value.knownModels ?? [] }
        speaker.onCloudUse = { [weak self] in self?.usage.add(Usage()) }
        speaker.onMissingVoice = { [weak self] lang in
            guard let self, !self.voicesOffered.contains(lang) else { return }
            self.voicesOffered.insert(lang)
            self.flash("There's no \(Language.name(lang)) voice on this Mac yet, so it may sound off.", action: "Get the voice") {
                NSWorkspace.shared.open(Links.spokenContent)
            }
        }
        speaker.onFallback = { [weak self] why in
            guard let self else { return }
            self.log("Gemini voice unavailable, used the Mac voice: \(why)")
            // Say so once a day, not on every reply, and offer the free Mac voice.
            guard Date().timeIntervalSince(self.voiceFallbackNoted) > 6 * 3600 else { return }
            self.voiceFallbackNoted = Date()
            self.flash("The Gemini voice is out of free requests, so I'm using the Mac voice for now.", action: "Always use Mac voice") { [weak self] in
                self?.store.value.voiceEngine = "apple"
                self?.flash("Using the Mac voice")
            }
        }
        scheduler.onFire = { [weak self] auto in self?.submit(auto.prompt, notifyWhenDone: true) }
        memory.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.facts = self.memory.facts
                self.automations = self.memory.automations
                self.about = self.memory.about
                self.scheduler.reschedule()
            }
        }
        facts = memory.facts
        automations = memory.automations
        about = memory.about
        HotKey.action = { [weak self] in self?.hotkeyPressed() }
    }

    // MARK: Lifecycle

    /// Called once at launch.
    func start() {
        guard !started else { return }
        started = true
        installKillSwitch()
        scheduler.reschedule()
        Notifier.shared.register()
        Notifier.shared.onAction = { [weak self] action, info, typed in self?.handleNotification(action, info, typed) }
        if bundled, !needsOnboarding { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        applySettings()
        voices = VoiceCatalog.all()
        refreshPermissions()
        Task { ollamaModels = await LocalBrain.shared.ollamaModels(fresh: true) }
        if !needsOnboarding { startListening() }
        telemetry.setActive(wantsTelemetry)
        startHealthWatch()
        if store.value.rememberConversations { restoreHistory() } else { memory.clearConversation() }
        if !needsOnboarding, store.value.greetOnLaunch, store.value.speakReplies {
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self else { return }
                self.speaker.say(self.greeting(), settings: self.store.value)
            }
        }
        refreshModelList()
    }

    /// Shows the earlier answers again after a restart.
    private func restoreHistory() {
        let turns = memory.turns
        var out: [Exchange] = []
        var i = 0
        while i + 1 < turns.count {
            if turns[i].role == "user", turns[i + 1].role == "assistant" {
                out.append(Exchange(question: turns[i].text, answer: turns[i + 1].text, source: turns[i + 1].source ?? "", at: turns[i + 1].at))
                i += 2
            } else {
                i += 1
            }
        }
        history = Array(out.suffix(30))
    }

    func startListening() {
        Task {
            guard await VoiceEngine.authorize() else {
                log("Microphone or speech permission is off.")
                return
            }
            do { try voice.start() } catch { log("Couldn't start the microphone: \(error.localizedDescription)") }
        }
    }

    private func applySettings() {
        let s = store.value
        voice.wakeEnabled = s.wakeWordEnabled
        voice.wakeWord = s.wakeWord
        voice.threshold = Float(s.micThreshold)
        voice.pause = s.responsePause
        voice.vocabulary = [s.userName, s.userName.split(separator: " ").first.map(String.init) ?? ""].filter { !$0.isEmpty }
        voice.bargeInEnabled = s.bargeIn
        voice.lockEnabled = s.voiceLockEnabled
        voice.lockStrictness = s.voiceLockStrictness
        hotKey.set(s.hotkey)
        if s.aboutText != memory.about { memory.setAbout(s.aboutText) }
        guard started else { return }
        telemetry.setActive(wantsTelemetry)
        if dockShown != s.showInDock {
            dockShown = s.showInDock
            NSApp.setActivationPolicy(s.showInDock ? .regular : .accessory)
        }
        if bundled {
            let svc = SMAppService.mainApp
            if s.launchAtLogin, svc.status != .enabled { try? svc.register() }
            if !s.launchAtLogin, svc.status == .enabled { try? svc.unregister() }
        }
    }

    // MARK: Onboarding

    func acceptTerms() {
        UserDefaults.standard.set(Terms.version, forKey: "jarvis.terms.version")
        UserDefaults.standard.set(ISO8601DateFormatter().string(from: Date()), forKey: "jarvis.terms.date")
        termsAccepted = true
    }

    var termsAcceptedOn: String {
        guard let s = UserDefaults.standard.string(forKey: "jarvis.terms.date"),
              let d = ISO8601DateFormatter().date(from: s) else { return "not yet" }
        return d.formatted(date: .long, time: .shortened)
    }

    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "jarvis.onboarded")
        UserDefaults.standard.set(3, forKey: "jarvis.onboarding.version")
        onboarded = true
        if bundled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        startListening()
        telemetry.setActive(wantsTelemetry)
        let hello = store.value.userName.isEmpty ? "Hello. I'm ready when you are." : "Hello \(store.value.userName). I'm ready when you are."
        reply(hello)
    }

    func replayOnboarding() {
        onboardingStart = 0
        onboarded = false
        showWindow()
    }

    /// Opens the spoken getting-to-know-you chat again.
    func talkAgain() {
        onboardingStart = OnboardingView.interviewStep
        onboarded = false
        showWindow()
    }

    func refreshPermissions() { permissions = Permissions.status() }

    /// Clears stale permission records and relaunches, so macOS asks once, cleanly.
    func repairPermissions() {
        Task {
            _ = await Permissions.reset()
            let path = Bundle.main.bundlePath
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
            try? p.run()
            NSApp.terminate(nil)
        }
    }

    // MARK: Input

    /// The global shortcut: open the floating ask bar and start listening.
    func hotkeyPressed() {
        guard !needsOnboarding else { showWindow(); return }
        let hudKey = NSApp.windows.contains { $0.identifier?.rawValue.contains("hud") == true && $0.isKeyWindow }
        if store.value.quickPanel, !hudKey {
            if quickActive, phase == .listening { closeQuick(); return }
            quickActive = true
            overlayVisible = true
        }
        pushToTalk()
    }

    func closeQuick() {
        quickActive = false
        if phase == .listening { voice.disarm() }
        refreshOverlay()
    }

    /// Opens the connection to Gemini while the user is still talking, so the answer starts sooner.
    /// Listing models is free and doesn't count against any quota.
    func warmCloud() {
        let key = store.geminiKey
        guard !key.isEmpty, Date().timeIntervalSince(lastWarm) > 45 else { return }
        lastWarm = Date()
        Task.detached(priority: .utility) {
            var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/models?pageSize=1")!)
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            req.timeoutInterval = 5
            _ = try? await URLSession.shared.data(for: req)
        }
    }

    func pushToTalk() {
        guard !needsOnboarding else { showWindow(); return }
        warmCloud()
        speaker.stop()
        voice.suspended = false
        voice.arm(push: true)
        LocalBrain.shared.prewarm(store.value)
        if !voice.running { startListening() }
    }

    func stopEverything() {
        KillSwitch.shared.trip()
        job?.cancel()
        speaker.stop()
        voice.disarm()
        highlight = nil
        steps = steps.map { var s = $0; if s.state == .running { s.state = .failed }; return s }
        phase = .idle
        setWorkload(0)
    }

    func submit(_ text: String, notifyWhenDone: Bool = false) {
        notifyAnswer = notifyWhenDone
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needsOnboarding, !t.isEmpty || !attachments.isEmpty else { return }
        if t.isEmpty { t = attachments.count == 1 ? "What is this? Summarise it." : "What are these? Summarise them." }
        let files = attachments
        attachments = []
        typed = ""
        job?.cancel()
        job = Task { await handle(t, files: files) }
    }

    static let spokenTask = """
    My request is in the attached audio and may be in any language. Do what I ask. Start your reply with one line in exactly this form: Heard: <my words, in the language I spoke>. Then answer in the language I spoke.
    """

    /// A spoken request. Confident English is handled as text; anything else goes to Gemini as audio,
    /// which understands most languages, so you can talk to Jarvis in yours.
    private func heard(_ text: String) {
        let conf = voice.lastConfidence
        if store.value.anyLanguage, !store.geminiKey.isEmpty, conf > 0, conf < 0.5 || text.count < 2,
           let wav = voice.lastRecordingWAV(), wav.count > 8_000 {
            log(String(format: "Speech wasn't clear English (%.0f%% sure), sending the audio to Gemini", conf * 100))
            guard !needsOnboarding else { return }
            attachments = []
            job?.cancel()
            job = Task { await handle(Self.spokenTask, files: [Attachment.speech(wav)], spoken: true) }
            return
        }
        submit(text)
    }

    /// Asks the last question again.
    func regenerate() {
        guard !question.isEmpty, !busy else { return }
        let q = question, files = lastAttachments
        job?.cancel()
        job = Task { await handle(q, files: files) }
    }

    /// Puts the last question back in the box to change it.
    func editLast() {
        guard !question.isEmpty else { return }
        typed = question
        attachments = lastAttachments
    }

    // MARK: Attachments

    func attach(_ urls: [URL]) {
        for u in urls {
            do {
                let a = try Attachment.load(u)
                guard attachments.reduce(0, { $0 + $1.size }) + a.size <= Attachment.maxTotal else {
                    flash("That's more than Jarvis can send at once (about 18 MB).")
                    return
                }
                attachments.append(a)
            } catch {
                flash(error.localizedDescription)
            }
        }
    }

    func attachImage(_ data: Data, name: String = "Pasted image") {
        do { attachments.append(try Attachment.image(data, name: name)) } catch { flash(error.localizedDescription) }
    }

    func attachScreenshot() {
        Task {
            do {
                let shot = try await Screen.capture(maxDim: 2048)
                attachImage(shot.jpeg, name: "Screenshot")
            } catch {
                flash(Friendly.message(error))
            }
        }
    }

    func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = "Choose files for Jarvis: images, PDFs, documents, code, audio or short videos."
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK { attach(panel.urls) }
    }

    func removeAttachment(_ id: UUID) { attachments.removeAll { $0.id == id } }

    /// jarvis://ask?q=... and jarvis://listen let Shortcuts and Siri hand Jarvis a request.
    func handle(url: URL) {
        switch url.host {
        case "ask":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            if let q { submit(q) } else { pushToTalk() }
        case "listen":
            hotkeyPressed()
        default:
            showWindow()
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash("Copied")
    }

    func copyAnswer() { copy(answer) }

    func speakAgain() {
        guard !answer.isEmpty else { return }
        speaker.say(Self.spoken(answer), settings: store.value, queue: false)
    }

    func clearHistory() {
        history.removeAll()
        memory.clearConversation()
        question = ""
        answer = ""
        steps = []
    }

    // MARK: Pipeline

    private func handle(_ text: String, files: [Attachment] = [], spoken: Bool = false) async {
        guard termsAccepted else { showWindow(); return }
        let began = Date()
        phase = .thinking
        question = spoken ? "…" : text
        lastAttachments = files
        answer = ""
        answerMarkdown = ""
        streamSpoken = 0
        streamSpokenText = ""
        answerSource = ""
        steps = []
        overlayText = text
        KillSwitch.shared.reset()
        log("You: \(text)")

        let s = store.value
        var mode = router.heuristic(text)
        setWorkload(0.12)

        // A follow-up goes wherever the previous request went, with the conversation attached.
        let previous = memory.context().last { $0.role == "assistant" }
        var followUp = false
        if let prev = previous, Date().timeIntervalSince(prev.at) < 20 * 60, Router.isFollowUp(text),
           let m = prev.mode, m != "local", let pm = Mode(rawValue: m) {
            mode = pm
            followUp = true
        }
        // Switches in the composer win, and attachments always go to a model that can see them.
        let forced: Mode? = screenOn ? .screen : searchOn ? .web : thinkOn ? .hard : nil
        if let forced { mode = forced }
        if forced != nil || !files.isEmpty { followUp = true }
        if !files.isEmpty, mode == nil { mode = .chat }
        if !files.isEmpty { apply(ActionEvent(title: "Reading \(files.count == 1 ? files[0].name : "\(files.count) files")", detail: files.map(\.name).joined(separator: ", "), state: .done, icon: "paperclip")) }

        // Questions about the Mac itself: answered from a live reading, on this Mac when possible.
        if !followUp, Router.isMacStatus(text) {
            let snap = SystemMonitor.shared.snapshot()
            let top = await SystemMonitor.shared.topProcesses()
            let report = SystemMonitor.report(snap, top: top)
            apply(ActionEvent(title: "Checked your Mac", detail: nil, state: .done, icon: "gauge.with.dots.needle.67percent"))
            switch await answerLocally(text, began: began, context: "Live data about this Mac right now:\n" + report) {
            case .answered: return
            case .escalate, .unavailable:
                if store.geminiKey.isEmpty && store.claudeKey.isEmpty {
                    record(text, SystemMonitor.spokenSummary(snap), source: "On this Mac · \(Self.elapsed(began))", mode: "local")
                    return
                }
                mode = .chat
            }
        } else if !followUp, mode == nil || mode == .chat, !Router.needsTools(text),
                  s.usageSaver || (!Router.isSubstantive(text) && Language.isEnglish(text)) {
            // Small talk and quick questions are answered on this Mac: free, private and fast.
            switch await answerLocally(text, began: began) {
            case .answered: return
            case .escalate(let m): mode = m
            case .unavailable: break
            }
        }

        // No cloud model can take this right now (no key, or every model is out of free requests): answer here.
        let cloudReady = !store.claudeKey.isEmpty || (!store.geminiKey.isEmpty &&
            router.chain(for: mode ?? .chat, settings: s).contains { QuotaBook.shared.usable($0) })
        if !cloudReady {
            if files.isEmpty, mode != .screen, await answerLocally(text, began: began, solo: true) == .answered { return }
            reply(store.geminiKey.isEmpty ? "I need a Gemini API key for that. You can add one in Settings."
                                          : Friendly.allResting(router.chain(for: mode ?? .chat, settings: s)))
            return
        }
        guard !usage.overCap(s.dailyRequestCap) else {
            reply("You've reached today's request limit. You can raise it in Settings.")
            return
        }
        let client = GeminiClient(apiKey: store.geminiKey)

        do {
            // Anything not obviously web, screen or deep thinking goes to the tool-using assistant, which can
            // search the web or take over the screen itself; no separate request is spent on sorting it.
            var m = mode ?? .chat
            setWorkload(Self.weight(of: m))
            let logger: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.log(line) } }

            var mcpTools: [MCPTool] = []
            if s.mcpServers.contains(where: { $0.enabled }), m != .web {
                let id = UUID()
                apply(ActionEvent(id: id, title: "Connecting tool servers", state: .running, icon: "puzzlepiece.extension"))
                mcpTools = await MCPHub.shared.tools(for: s.mcpServers, log: logger)
                apply(ActionEvent(id: id, title: "Connecting tool servers", detail: "\(mcpTools.count) tools ready", state: .done, icon: "puzzlepiece.extension"))
            }

            if m == .screen { stepAside() }
            var override: Tier?
            var outcome: AgentOutcome
            var provider = ""
            var handedToScreen = false
            while true {
                phase = m == .screen ? .acting : .thinking
                let tools = makeTools(s, mcp: mcpTools)
                // Effort decides how strong a model everyday questions get; the usage saver keeps to Lite.
                var deep: Tier?
                if m == .chat, s.modelChoice == "auto", !s.usageSaver {
                    let substantive = Router.isSubstantive(text) || !files.isEmpty
                    switch s.effort {
                    case "low": deep = nil
                    case "high": deep = .flash
                    case "max": deep = substantive ? .pro : .flash
                    default: deep = substantive ? .flash : nil
                    }
                }
                (outcome, provider) = try await runAgent(text, files: files, mode: m, tier: override ?? deep ?? router.tier(for: m, settings: s),
                                                         chain: router.chain(for: m, settings: s, from: override ?? deep),
                                                         client: client, tools: tools, settings: s, log: logger)
                // The model decided this needs the screen: run it again with eyes and hands.
                if outcome.needsScreen, !handedToScreen, !KillSwitch.shared.tripped {
                    handedToScreen = true
                    apply(ActionEvent(title: "Switching to screen control", detail: outcome.summary, state: .done, icon: "display"))
                    m = .screen
                    setWorkload(1)
                    stepAside()
                    continue
                }
                // One retry on the strongest model if the first attempt gave up by itself.
                if !outcome.success, !KillSwitch.shared.tripped, override == nil, m == .screen,
                   let up = router.escalation(from: m, settings: s) {
                    log("Retrying with the \(up.rawValue) model")
                    override = up
                    setWorkload(1)
                    continue
                }
                break
            }
            var answerText = outcome.summary
            var said = files.isEmpty ? text : text + " " + files.map(\.mention).joined(separator: " ")
            if spoken {
                let split = Language.splitHeard(outcome.summary)
                said = split.heard ?? "(spoken request)"
                question = said
                answerText = split.rest.isEmpty ? outcome.summary : split.rest
            }
            record(said, answerText, source: "\(provider) · \(Self.elapsed(began))", mode: m.rawValue)
        } catch is CancellationError {
            phase = .idle
        } catch {
            // The cloud failed (offline, limits, an outage): answer on this Mac rather than leave you waiting.
            if !spoken, files.isEmpty, mode != .screen, await answerLocally(text, began: began, solo: true) == .answered {
                log("Cloud failed, answered on this Mac: \(Friendly.message(error))")
            } else {
                reply(Friendly.message(error))
            }
        }
        comeBack()
    }

    private func makeTools(_ s: JarvisSettings, mcp: [MCPTool]) -> ToolBox {
        let key = store.geminiKey
        let tracker = usage
        var search: (@Sendable (String) async -> String)?
        if !key.isEmpty {
            search = { q in
                await AppModel.webSearch(q, key: key, settings: s) { u in Task { @MainActor in tracker.add(u) } }
            }
        }
        return ToolBox(
            settings: s, memory: memory,
            confirm: { [weak self] q in await self?.askPermission(q) ?? false },
            notify: { [weak self] title, body in Task { @MainActor in self?.notify(title, body) } },
            onAction: { [weak self] e in Task { @MainActor in self?.apply(e) } },
            mcp: mcp,
            search: search,
            setSetting: { [weak self] name, value in await self?.changeSetting(name, value) ?? "Couldn't change that." }
        )
    }

    /// Grounded Google Search through Gemini, returned as text with its sources.
    nonisolated private static func webSearch(_ q: String, key: String, settings s: JarvisSettings, usage: @escaping @Sendable (Usage) -> Void) async -> String {
        let client = GeminiClient(apiKey: key)
        let models = ([s.flashModel] + ModelPicker.ranked(.flash, in: s.knownModels).prefix(2) + [s.liteModel]).filter { QuotaBook.shared.usable($0) }
        for model in models {
            do {
                let r = try await client.generate(model: model, system: "Search the web and answer with the key facts, figures and dates. Plain text, under 150 words.",
                                                  contents: [["role": "user", "parts": [["text": q]]]],
                                                  tools: [["google_search": [String: Any]()]], maxTokens: 700,
                                                  thinking: GeminiAgent.thinking(for: model, mode: .web))
                usage(r.usage)
                var out = r.text
                if !r.sources.isEmpty { out += "\nSources: " + r.sources.prefix(4).map { "\($0.title) (\(URL(string: $0.url)?.host ?? $0.url))" }.joined(separator: "; ") }
                return out.isEmpty ? "No results." : out
            } catch {
                continue
            }
        }
        return "Couldn't search the web right now."
    }

    /// Settings Jarvis may change when asked out loud.
    private func changeSetting(_ name: String, _ value: String) -> String {
        let v = value.trimmingCharacters(in: .whitespaces)
        let on = ["true", "on", "yes", "1"].contains(v.lowercased())
        switch name {
        case "speakReplies": store.value.speakReplies = on
        case "voiceRate": guard let d = Double(v) else { return "Rate must be a number." }; store.value.voiceRate = min(0.65, max(0.3, d))
        case "voiceEngine": guard ["apple", "gemini"].contains(v) else { return "Use apple or gemini." }; store.value.voiceEngine = v
        case "geminiVoice": guard GeminiVoice.voices.contains(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame }) else { return "Unknown voice." }
            store.value.geminiVoice = GeminiVoice.voices.first { $0.name.caseInsensitiveCompare(v) == .orderedSame }!.name
        case "theme": guard ["dark", "light", "system"].contains(v) else { return "Use dark, light or system." }; store.value.theme = v
        case "modelChoice": guard ["auto", "lite", "flash", "pro"].contains(v) else { return "Use auto, lite, flash or pro." }; store.value.modelChoice = v
        case "wakeWordEnabled": store.value.wakeWordEnabled = on
        case "narrateActions": store.value.narrateActions = on
        case "showHighlights": store.value.showHighlights = on
        case "reduceMotion": store.value.reduceMotion = on
        case "healthAlerts": store.value.healthAlerts = on
        case "showTelemetry": store.value.showTelemetry = on
        case "userName": store.value.userName = v
        default: return "That setting can't be changed by voice. It's in Settings."
        }
        return "Changed \(name) to \(v)."
    }

    private enum LocalResult: Equatable { case answered, escalate(Mode), unavailable }

    /// Streams the local model's answer and starts speaking at the first full sentence.
    private func answerLocally(_ text: String, began: Date, context: String? = nil, solo: Bool = false) async -> LocalResult {
        let s = store.value
        let profile = memory.profile(name: s.userName)
        let ctx = [profile.isEmpty ? nil : "What you know about the user:\n" + profile, context].compactMap { $0 }.joined(separator: "\n\n")
        guard let (stream, engine) = await LocalBrain.shared.stream(text, history: chatHistory(), settings: s, context: ctx.isEmpty ? nil : ctx, solo: solo) else {
            return .unavailable
        }
        let streamSpeech = s.speakReplies && s.voiceEngine != "gemini"
        var latest = ""
        var spoken = 0
        var decided = false
        do {
            for try await partial in stream {
                if Task.isCancelled { return .answered }
                latest = partial
                if !decided, !solo {
                    switch LocalBrain.verdict(partial, finished: false) {
                    case .escalate(let m)?:
                        log("On-device model handed this to the cloud (\(m.rawValue))")
                        return .escalate(m)
                    case .answer?:
                        decided = true
                    case nil:
                        continue
                    }
                }
                answer = Self.clean(partial)
                overlayText = answer
                if streamSpeech { spoken = speakSentences(answer, from: spoken, s) }
            }
        } catch {
            log("On-device model failed: \(error.localizedDescription)")
            if !decided { return .unavailable }
        }
        if !solo, case .escalate(let m)? = LocalBrain.verdict(latest, finished: true), !decided { return .escalate(m) }

        let final = Self.clean(latest)
        answerMarkdown = latest.trimmingCharacters(in: .whitespacesAndNewlines)
        answer = final
        overlayText = final
        answerSource = "\(engine == .apple ? "On this Mac" : "Local model")\(solo ? " · offline" : "") · \(Self.elapsed(began))"
        if s.speakReplies {
            if streamSpeech {
                let rest = String(final.dropFirst(spoken)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { speaker.sayLocal(rest, settings: s) }
            } else {
                speaker.say(Self.spoken(final), settings: s)
            }
        }
        remember(text, final, source: answerSource, mode: "local")
        if !speaker.isSpeaking { phase = .idle }
        setWorkload(0)
        refreshOverlay()
        return .answered
    }

    /// Speaks any sentences completed since `start` and returns the new position.
    private func speakSentences(_ text: String, from start: Int, _ s: JarvisSettings) -> Int {
        let chars = Array(text)
        guard chars.count > start + 1 else { return start }
        var end = -1
        var i = chars.count - 2
        while i >= start {
            if ".!?".contains(chars[i]), chars[i + 1] == " " || chars[i + 1] == "\n" { end = i + 1; break }
            i -= 1
        }
        guard end > start else { return start }
        let sentence = String(chars[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        if !sentence.isEmpty { speaker.sayLocal(sentence, settings: s) }
        return end
    }

    /// Claude first when it's set up and healthy; any failure drops straight to Gemini.
    private func runAgent(_ text: String, files: [Attachment] = [], mode: Mode, tier: Tier, chain: [String], client: GeminiClient, tools: ToolBox,
                          settings s: JarvisSettings, log logger: @escaping @Sendable (String) -> Void) async throws -> (AgentOutcome, String) {
        if s.claudeEnabled, !store.claudeKey.isEmpty, mode != .web, !files.contains(where: \.needsGemini), Date() >= claudeBlockedUntil {
            let model = s.claudeModelID(tier)
            let agent = ClaudeAgent(client: ClaudeClient(apiKey: store.claudeKey), model: model, settings: s,
                                    tools: tools, tracker: usage, profile: memory.profile(name: s.userName), log: logger)
            do {
                return (try await agent.run(task: text, mode: mode, history: chatHistory(), attachments: files), "Claude")
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as LLMError {
                if case .other = e { throw e }   // permission problems would fail on Gemini too
                if case .http(let code, _) = e, [400, 401, 402, 403].contains(code) {
                    claudeBlockedUntil = Date().addingTimeInterval(30 * 60)   // no credits or bad key: stop trying for a while
                }
                log("Claude unavailable, using Gemini. \(Friendly.message(e))")
            } catch {
                log("Claude unavailable, using Gemini.")
            }
        }
        guard !store.geminiKey.isEmpty else {
            throw LLMError.other("Claude didn't work and there's no Gemini key. Add one in Settings.")
        }
        let agent = GeminiAgent(client: client, chain: chain, settings: s, tools: tools, tracker: usage,
                                profile: memory.profile(name: s.userName), log: logger)
        agent.onText = { [weak self] t in Task { @MainActor in self?.streamed(t, mode: mode) } }
        return (try await agent.run(task: text, mode: mode, history: chatHistory(), attachments: files), "Gemini")
    }

    // MARK: Tests

    func testGemini() async {
        testing = true
        defer { testing = false }
        let (lines, models) = await ConnectionTest.gemini(key: store.geminiKey, settings: store.value)
        var out = lines
        if !models.isEmpty {
            availableModels = models
            store.value.knownModels = models
            out += useNewestModels(from: models)
        }
        geminiTest = out
    }

    func testClaude() async {
        testing = true
        defer { testing = false }
        claudeTest = await ConnectionTest.claude(key: store.claudeKey, model: store.value.claudeLiteModel)
    }

    func testLocal() async {
        testing = true
        defer { testing = false }
        var lines: [TestLine] = []
        let apple = LocalBrain.shared.appleStatus()
        lines.append(TestLine(kind: apple.ready ? .ok : .warn, text: apple.detail))
        ollamaModels = await LocalBrain.shared.ollamaModels(fresh: true)
        lines.append(ollamaModels.isEmpty
            ? TestLine(kind: .warn, text: "Ollama isn't running. It's optional: install it from ollama.com, then run \"ollama pull llama3.2:3b\".")
            : TestLine(kind: .ok, text: "Ollama is running with: \(ollamaModels.prefix(4).joined(separator: ", "))."))
        let began = Date()
        if let (stream, engine) = await LocalBrain.shared.stream("Say hello in three words.", history: [], settings: store.value) {
            var first: TimeInterval?
            var text = ""
            do {
                for try await p in stream {
                    if first == nil { first = Date().timeIntervalSince(began) }
                    text = p
                }
                let who = engine == .apple ? "Apple's on-device model" : "Ollama"
                lines.append(TestLine(kind: .ok, text: "\(who) replied \"\(text.prefix(40))\". First words after \(String(format: "%.2f", first ?? 0)) s."))
            } catch {
                lines.append(TestLine(kind: .fail, text: "The local model failed: \(error.localizedDescription)"))
            }
        } else {
            lines.append(TestLine(kind: .warn, text: "No local model is available, so every request goes to Gemini."))
        }
        localTest = lines
    }

    /// Points each tier at the newest model this key can use, when the current one isn't available.
    @discardableResult
    func useNewestModels(from models: [String]? = nil) -> [TestLine] {
        let list = models ?? availableModels
        var out: [TestLine] = []
        for tier in Tier.allCases {
            let current = store.value.modelID(tier)
            guard !list.contains(current), let best = ModelPicker.newest(tier, in: list) else { continue }
            switch tier {
            case .lite: store.value.liteModel = best
            case .flash: store.value.flashModel = best
            case .pro: store.value.proModel = best
            }
            out.append(TestLine(kind: .ok, text: "Switched \(tier.rawValue) to \(best)."))
        }
        return out
    }

    // MARK: Mac care

    /// Every five minutes, a cheap reading; anything worrying is said once an hour at most.
    /// One light reading every ten minutes (a few numbers from macOS, no app scanning). Nothing is said
    /// unless the Mac has been under extreme strain for a long stretch, and then only as a quiet notification.
    private func startHealthWatch() {
        healthTimer?.invalidate()
        healthTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkHealth() }
        }
        healthTimer?.tolerance = 120
    }

    private func checkHealth() {
        guard store.value.healthAlerts, !needsOnboarding else { extremeSince.removeAll(); return }
        let now = Date()
        let current = SystemMonitor.extremeItems(SystemMonitor.shared.snapshot())
        let kinds = Set(current.map(\.kind))
        extremeSince = extremeSince.filter { kinds.contains($0.key) }
        for a in current {
            let since = extremeSince[a.kind] ?? now
            extremeSince[a.kind] = since
            guard now.timeIntervalSince(since) >= SystemMonitor.patience(a.kind) else { continue }
            if let last = lastAlerts[a.kind.rawValue], now.timeIntervalSince(last) < 3 * 3600 { continue }
            lastAlerts[a.kind.rawValue] = now
            let kind: Notifier.Kind
            switch a.kind {
            case .battery, .batteryHealth: kind = .battery
            case .storage: kind = .storage
            case .memory: kind = .memory
            case .thermal: kind = .thermal
            }
            Notifier.shared.post(kind, title: "Your Mac", body: a.text)
        }
    }

    // MARK: Showing what's happening

    private func apply(_ e: ActionEvent) {
        if let i = steps.firstIndex(where: { $0.id == e.id }) {
            steps[i].state = e.state
            if let d = e.detail { steps[i].detail = d }
        } else {
            steps.append(Step(id: e.id, title: e.title, detail: e.detail, state: e.state, icon: e.icon))
        }
        guard e.state == .running else { return }
        overlayText = e.title
        if let p = e.point, store.value.showHighlights {
            highlight = Highlight(point: p, title: e.title)
            highlightTask?.cancel()
            highlightTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                if !Task.isCancelled { self?.highlight = nil }
            }
        }
        if store.value.narrateActions, store.value.speakReplies, !speaker.isSpeaking {
            speaker.sayLocal(e.title, settings: store.value)
        }
    }

    /// Screen tasks: move the main window out of the way so Jarvis can see and use the screen.
    private func stepAside() {
        let visible = NSApp.windows.filter { $0.identifier?.rawValue.contains("hud") == true && $0.isVisible }
        if !visible.isEmpty { hudWasVisible = true }
        visible.forEach { $0.orderOut(nil) }
        if store.value.overlayEnabled { overlayVisible = true }
    }

    /// Brings the window back without stealing focus from the app Jarvis just used.
    private func comeBack() {
        guard hudWasVisible else { return }
        hudWasVisible = false
        NSApp.windows.first { $0.identifier?.rawValue.contains("hud") == true }?.orderFront(nil)
    }

    func showWindow() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("hud") == true && $0.isVisible }) {
            w.makeKeyAndOrderFront(nil)
        } else if let open = openMainWindow {
            open()
        } else {
            NSApp.windows.first { $0.identifier?.rawValue.contains("hud") == true }?.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func askPermission(_ question: String) async -> Bool {
        if store.value.speakReplies { speaker.sayLocal("Should I go ahead?", settings: store.value, queue: false) }
        let alert = NSAlert()
        alert.messageText = "Jarvis wants to continue"
        alert.informativeText = question
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notify(_ title: String, _ body: String) {
        overlayText = body
        overlayVisible = store.value.overlayEnabled
        if store.value.speakReplies { speaker.say(body, settings: store.value) }
        Notifier.shared.post(title == "Timer" ? .timer : .general, title: title == "Timer" ? "Timer" : title, body: body)
        refreshOverlay()
    }

    /// Shows, speaks and keeps a finished answer.
    private func record(_ q: String, _ a: String, source: String, mode: String) {
        reply(a, source: source)
        remember(q, Self.clean(a), source: source, mode: mode)
        if notifyAnswer {
            notifyAnswer = false
            Notifier.shared.post(.answer, title: "Jarvis · \(q.prefix(60))", body: Self.clean(a), info: ["question": q])
        }
    }

    // MARK: Greetings

    private var firstName: String { store.value.userName.split(separator: " ").first.map(String.init) ?? "" }

    /// What Jarvis says when called by name with nothing else.
    func acknowledgement() -> String {
        let n = firstName
        let options = n.isEmpty ? ["Yes?", "I'm listening.", "Go ahead."] : ["Yes, \(n)?", "Hey \(n)?", "I'm listening, \(n).", "Go ahead, \(n)."]
        return options.randomElement() ?? "Yes?"
    }

    /// What Jarvis says when it starts.
    func greeting() -> String {
        let n = firstName
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 5 ? "Hey" : h < 12 ? "Good morning" : h < 17 ? "Good afternoon" : h < 22 ? "Good evening" : "Hey"
        return n.isEmpty ? "\(part). I'm here when you need me." : "\(part), \(n). I'm here when you need me."
    }

    // MARK: Notification actions

    private func handleNotification(_ action: String, _ info: [String: String], _ typed: String?) {
        let body = info["body"] ?? ""
        func ask(_ q: String) { showWindow(); submit(q) }
        switch action {
        case "reply":
            if let t = typed, !t.trimmingCharacters(in: .whitespaces).isEmpty { submit(t) }
        case "copy": copy(body)
        case "speak": speaker.say(Self.spoken(body), settings: store.value, queue: false)
        case "snooze":
            Notifier.shared.post(.timer, title: "Timer", body: body, after: 300)
            flash("Snoozed for 5 minutes")
        case "dismiss": break
        case "freeSpace": ask("Free up some disk space. Show me what's safe to remove first.")
        case "storageReport": ask("What's taking up my disk space?")
        case "batteryDrain": ask("What's using my battery? Which apps use the most energy right now?")
        case "batterySettings":
            if let u = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") { NSWorkspace.shared.open(u) }
        case "memoryHogs": ask("What's using my memory right now?")
        case "cpuHogs": ask("Which apps are using the most CPU right now?")
        default:
            showWindow()
            if info["kind"] == "answer", !body.isEmpty, answer.isEmpty || answer != body {
                question = info["question"] ?? question
                answer = body
                answerMarkdown = body
            }
        }
    }

    /// The conversation so far, for the models.
    /// Long earlier answers are trimmed, since the model only needs the gist to follow the thread.
    private func chatHistory() -> [(role: String, text: String)] {
        memory.context(limit: store.value.usageSaver ? 4 : 10).map { t in
            (t.role, t.role == "assistant" && t.text.count > 700 ? String(t.text.prefix(700)) + "…" : t.text)
        }
    }

    // MARK: Streaming

    private var streamSpoken = 0
    private var streamSpokenText = ""

    /// Shows a cloud answer as it's written. Web answers (which can't involve tool steps) also start
    /// speaking at the first full sentence when the Mac voice is in use.
    private func streamed(_ raw: String, mode: Mode) {
        guard busy else { return }
        var t = raw
        if t.lowercased().hasPrefix("heard:") {
            t = Language.splitHeard(t).rest
            guard !t.isEmpty else { return }
        }
        answerMarkdown = t
        answer = Self.clean(t)
        overlayText = answer
        let s = store.value
        if mode == .web, s.speakReplies, s.voiceEngine != "gemini" || s.usageSaver {
            streamSpoken = speakSentences(answer, from: streamSpoken, s)
            streamSpokenText = String(answer.prefix(streamSpoken))
        }
    }

    private func remember(_ q: String, _ a: String, source: String, mode: String) {
        memory.append(Turn(role: "user", text: q, mode: mode))
        memory.append(Turn(role: "assistant", text: a, mode: mode, source: source))
        if store.value.keepHistory {
            history.append(Exchange(question: q, answer: a, source: source, at: Date()))
            if history.count > 50 { history.removeFirst(history.count - 50) }
        }
        learn(from: q)
        setWorkload(0, after: 1.5)
    }

    /// Quietly notes lasting facts the user mentions about themselves.
    private func learn(from text: String) {
        let s = store.value
        guard s.learnAboutMe, !s.usageSaver, !store.geminiKey.isEmpty, Learner.worthChecking(text),
              Date().timeIntervalSince(lastLearn) > 20, !usage.overCap(s.dailyRequestCap) else { return }
        lastLearn = Date()
        let key = store.geminiKey, known = memory.facts, model = s.liteModel
        Task { [weak self] in
            let found = await Learner.learn(from: text, known: known, key: key, model: model)
            guard let self, !found.isEmpty else { return }
            found.forEach { self.memory.addFact($0) }
            self.log("Learned: " + found.joined(separator: " "))
            self.flash("Noted: " + found.joined(separator: " "), action: "Undo") { [weak self] in
                found.forEach { self?.memory.removeFact($0) }
                self?.flash("Forgotten")
            }
        }
    }

    // MARK: Adaptive colour

    static func weight(of m: Mode) -> Double {
        switch m {
        case .chat: return 0.3
        case .web: return 0.45
        case .hard: return 0.85
        case .screen: return 1
        }
    }

    private var workloadTask: Task<Void, Never>?

    func setWorkload(_ w: Double, after delay: TimeInterval = 0) {
        workloadTask?.cancel()
        workloadTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self, abs(self.workload - w) > 0.01 else { return }
            withAnimation(.easeInOut(duration: 0.9)) { self.workload = w }
        }
    }

    /// Learns which Gemini models this key can use (free; listing doesn't count against quota),
    /// so each tier has stand-ins when one model runs out of free requests.
    private func refreshModelList() {
        let key = store.geminiKey
        guard !key.isEmpty || !store.keysLoaded else { return }
        Task {
            if !store.keysLoaded { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            let k = store.geminiKey
            guard !k.isEmpty, let models = try? await GeminiClient(apiKey: k).listModels(), !models.isEmpty else { return }
            availableModels = models
            if store.value.knownModels != models { store.value.knownModels = models }
            useNewestModels(from: models)
        }
    }

    /// When live readings are switched on, a Mac under strain also warms the colour. Nothing polls for this.
    private func noteStrain(_ snap: MacSnapshot) {
        guard store.value.colorMode == "adaptive" else { return }
        let strained = snap.cpu > 0.85 || snap.thermal == "serious" || snap.thermal == "critical" || snap.pressure == "critical"
        if strained != systemStrained { withAnimation(.easeInOut(duration: 1.2)) { systemStrained = strained } }
    }

    // MARK: Ollama

    func setUpOllama() async {
        ollamaBusy = "Starting Ollama…"
        if !LocalBrain.ollamaInstalled {
            ollamaBusy = "Downloading Ollama (about 200 MB)…"
            pullProgress = 0
            do {
                try await LocalBrain.shared.installOllamaApp { [weak self] p in
                    Task { @MainActor in self?.pullProgress = p }
                }
            } catch {
                pullProgress = nil
                ollamaBusy = Friendly.message(error)
                return
            }
            pullProgress = nil
            ollamaBusy = "Starting Ollama…"
        }
        let up = await LocalBrain.shared.startOllama()
        ollamaModels = await LocalBrain.shared.ollamaModels(fresh: true)
        ollamaBusy = up ? nil : "Ollama is installed but didn't start. Open it from Applications, or run \"ollama serve\"."
    }

    func downloadModel(_ name: String) async {
        if !(await LocalBrain.shared.ollamaReachable()) { await setUpOllama() }
        guard await LocalBrain.shared.ollamaReachable() else { return }
        pullProgress = 0
        ollamaBusy = "Downloading \(name)…"
        do {
            try await LocalBrain.shared.pull(name) { [weak self] p, status in
                Task { @MainActor in
                    self?.pullProgress = p
                    if !status.isEmpty { self?.ollamaBusy = "Downloading \(name): \(status)" }
                }
            }
            ollamaModels = await LocalBrain.shared.ollamaModels(fresh: true)
            store.value.ollamaModel = name
            if store.value.localEngine == "apple" { store.value.localEngine = "auto" }
            ollamaBusy = nil
            flash("\(name) is ready")
        } catch {
            ollamaBusy = "Download failed: \(Friendly.message(error))"
        }
        pullProgress = nil
    }

    private func reply(_ text: String, source: String = "") {
        setWorkload(0, after: 1.5)
        answerMarkdown = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = Self.clean(text)
        answer = c
        answerSource = source
        overlayText = c
        phase = .idle
        if store.value.speakReplies {
            if streamSpokenText.isEmpty {
                speaker.say(Self.spoken(c), settings: store.value)
            } else if c.hasPrefix(streamSpokenText) {
                // Part of it was already spoken while it streamed in; say the rest.
                let rest = String(c.dropFirst(streamSpokenText.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { speaker.sayLocal(rest, settings: store.value) }
            }
            streamSpokenText = ""
            streamSpoken = 0
        }
        refreshOverlay()
    }

    func flash(_ text: String, action: String? = nil, run: (() -> Void)? = nil) {
        notice = text
        noticeAction = action
        noticeHandler = run
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: action == nil ? 2_500_000_000 : 6_000_000_000)
            if !Task.isCancelled { self?.notice = nil; self?.noticeAction = nil }
        }
    }

    func runNoticeAction() {
        let h = noticeHandler
        notice = nil
        noticeAction = nil
        noticeHandler = nil
        h?()
    }

    func dismissNotice() {
        notice = nil
        noticeAction = nil
    }

    func log(_ line: String) {
        diagnostics.append(Redact.secrets(line))
        if diagnostics.count > 200 { diagnostics.removeFirst(diagnostics.count - 200) }
    }

    private func refreshOverlay() {
        hideTask?.cancel()
        let hudFront = NSApp?.windows.contains { $0.identifier?.rawValue.contains("hud") == true && $0.isKeyWindow && $0.isVisible } ?? false
        if quickActive { overlayVisible = true; return }
        guard store.value.overlayEnabled, !hudFront else { overlayVisible = false; return }
        if phase != .idle {
            overlayVisible = true
        } else {
            guard !overlayHovered else { return }
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled, self?.quickActive == false, self?.overlayHovered == false { self?.overlayVisible = false }
            }
        }
    }

    /// Esc anywhere stops whatever Jarvis is doing. Jarvis's own key presses carry a marker and are ignored.
    private func installKillSwitch() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            guard e.keyCode == 53, e.cgEvent?.getIntegerValueField(.eventSourceUserData) != Input.marker else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.quickActive, !self.busy { self.closeQuick() } else { self.stopEverything() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] e in
            handler(e)
            // ⌘V with an image (and no text) on the clipboard attaches it, as in other AI apps.
            if e.modifierFlags.contains(.command), e.charactersIgnoringModifiers == "v", let self {
                let pb = NSPasteboard.general
                if pb.string(forType: .string) == nil, let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
                    Task { @MainActor in self.attachImage(data) }
                    return nil
                }
            }
            return e
        }) { monitors.append(l) }
    }

    // MARK: Text helpers

    static func elapsed(_ since: Date) -> String {
        String(format: "%.1f s", Date().timeIntervalSince(since))
    }

    /// Plain text for the answer card: no markdown symbols.
    static func clean(_ t: String) -> String {
        t.components(separatedBy: "\n").map { line -> String in
            var l = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "").replacingOccurrences(of: "`", with: "")
            while l.hasPrefix("#") { l.removeFirst() }
            let trimmed = l.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { l = "• " + trimmed.dropFirst(2) }
            return l.trimmingCharacters(in: .whitespaces)
        }
        .joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Long answers: speak the first couple of sentences and leave the rest on screen.
    static func spoken(_ t: String) -> String {
        guard t.count > 420 else { return t }
        var out = ""
        var count = 0
        t.enumerateSubstrings(in: t.startIndex..., options: .bySentences) { s, _, _, stop in
            guard let s else { return }
            out += s
            count += 1
            if count >= 2 || out.count > 300 { stop = true }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines) + " The rest is on screen."
    }
}

/// The classifier only needs one word, so it runs with the least thinking the model allows.
enum GeminiAgentThinking {
    static func minimal(_ model: String) -> Thinking? {
        if model.contains("pro") { return nil }
        return model.hasPrefix("gemini-2") ? .budget(0) : .level(model.contains("lite") ? "minimal" : "low")
    }
}

/// Live Mac readings for the HUD, sampled only while something on screen shows them.
@MainActor
final class Telemetry: ObservableObject {
    @Published private(set) var snapshot: MacSnapshot?
    @Published private(set) var cpu: [Double] = []
    @Published private(set) var memory: [Double] = []
    private var timer: Timer?
    private let keep = 40

    func setActive(_ on: Bool) {
        if on, timer == nil {
            sample()
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.sample() }
            }
            timer?.tolerance = 0.5
        } else if !on, let t = timer {
            t.invalidate()
            timer = nil
        }
    }

    private func sample() {
        Task.detached(priority: .utility) {
            let s = SystemMonitor.shared.snapshot()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.snapshot = s
                self.cpu.append(s.cpu)
                self.memory.append(s.memoryFraction)
                if self.cpu.count > self.keep { self.cpu.removeFirst() }
                if self.memory.count > self.keep { self.memory.removeFirst() }
            }
        }
    }
}
