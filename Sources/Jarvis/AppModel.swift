import SwiftUI
import AppKit
import Combine
import ServiceManagement
import UserNotifications
import JarvisCore

enum Phase: String {
    case idle, listening, thinking, acting
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store = SettingsStore()
    let usage = UsageTracker()
    let voice = VoiceEngine()
    let memory = MemoryStore()
    private lazy var scheduler = Scheduler(memory: memory)
    private let speaker = Speaker()
    private let router = Router()

    @Published var phase: Phase = .idle { didSet { refreshOverlay() } }
    @Published var feed: [String] = []
    @Published var typed = ""
    @Published var overlayVisible = false
    @Published var overlayText = ""
    @Published var availableModels: [String] = []
    @Published var facts: [String] = []
    @Published var automations: [Automation] = []

    private var history: [(role: String, text: String)] = []
    private var job: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var monitors: [Any] = []
    private var bag = Set<AnyCancellable>()
    private var started = false
    private var claudeBlockedUntil = Date.distantPast

    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var accent: Color {
        switch store.value.accent {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        default: return .cyan
        }
    }

    private init() {
        // Forward nested changes so views reading store/usage refresh.
        store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        usage.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        voice.$armed.sink { [weak self] armed in
            guard let self else { return }
            if armed, self.phase == .idle { self.phase = .listening }
            if !armed, self.phase == .listening { self.phase = .idle }
        }.store(in: &bag)
        voice.$partial.sink { [weak self] p in if !p.isEmpty { self?.overlayText = p } }.store(in: &bag)
        store.$value.sink { [weak self] _ in self?.applySettings() }.store(in: &bag)

        voice.onCommand = { [weak self] text in self?.submit(text) }
        speaker.onSpeakingChange = { [weak self] speaking in self?.voice.suspended = speaking }
        scheduler.onFire = { [weak self] auto in
            self?.log("Scheduled: \(auto.prompt)")
            self?.submit(auto.prompt)
        }
        memory.onChange = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.facts = self.memory.facts
                self.automations = self.memory.automations
                self.scheduler.reschedule()
            }
        }
        facts = memory.facts
        automations = memory.automations
    }

    /// Called once at launch: starts listening, scheduling and the Esc kill switch.
    func start() {
        guard !started else { return }
        started = true
        installKillSwitch()
        scheduler.reschedule()
        if bundled { UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in } }
        applySettings()
        Task {
            guard await VoiceEngine.authorize() else {
                log("Microphone or speech permission is off. Enable both in System Settings, Privacy and Security.")
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
        if bundled {
            let svc = SMAppService.mainApp
            if s.launchAtLogin, svc.status != .enabled { try? svc.register() }
            if !s.launchAtLogin, svc.status == .enabled { try? svc.unregister() }
        }
    }

    // MARK: Input

    func pushToTalk() {
        speaker.stop()
        voice.suspended = false
        voice.arm()
        if !voice.running { start() }
    }

    func stopEverything() {
        KillSwitch.shared.trip()
        job?.cancel()
        speaker.stop()
        voice.disarm()
        phase = .idle
    }

    func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        job?.cancel()
        job = Task { await handle(t) }
    }

    /// jarvis://ask?q=... lets Shortcuts and Siri hand Jarvis a request.
    func handle(url: URL) {
        switch url.host {
        case "ask":
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "q" }?.value
            if let q { submit(q) } else { pushToTalk() }
        case "listen":
            pushToTalk()
        default:
            break
        }
    }

    func refreshModels() {
        guard !store.geminiKey.isEmpty else { return }
        let client = GeminiClient(apiKey: store.geminiKey)
        Task {
            do { availableModels = try await client.listModels() }
            catch { log("Couldn't list models: \(error.localizedDescription)") }
        }
    }

    // MARK: Pipeline

    private func handle(_ text: String) async {
        phase = .thinking
        overlayText = text
        KillSwitch.shared.reset()
        log("You: \(text)")

        let s = store.value
        guard !store.geminiKey.isEmpty || !store.claudeKey.isEmpty else {
            reply("Add your Gemini API key in Settings first.")
            return
        }
        guard !usage.overCap(s.dailyRequestCap) else {
            reply("You've reached today's request limit. You can raise it in Settings.")
            return
        }
        let client = GeminiClient(apiKey: store.geminiKey)

        do {
            var mode = router.heuristic(text)
            if mode == nil, !store.geminiKey.isEmpty {
                let r = try await client.generate(model: s.liteModel, system: Router.classifierPrompt,
                                                  contents: [["role": "user", "parts": [["text": text]]]],
                                                  maxTokens: 8, thinkingBudget: 0)
                usage.add(r.usage)
                mode = Router.parse(r.text)
            }
            let m = mode ?? .chat
            var override: Tier?
            var outcome: AgentOutcome

            while true {
                let chain = router.chain(for: m, settings: s, from: override)
                log("\(m.rawValue) · \(chain.first ?? "")")
                if m == .screen { phase = .acting }

                let tools = ToolBox(
                    settings: s, memory: memory,
                    confirm: { [weak self] q in await self?.askPermission(q) ?? false },
                    notify: { [weak self] title, body in Task { @MainActor in self?.notify(title, body) } }
                )
                outcome = try await runAgent(text, mode: m, tier: override ?? router.tier(for: m, settings: s),
                                             chain: chain, client: client, tools: tools, settings: s)

                // One retry on the strongest model if the first attempt gave up by itself.
                if !outcome.success, !KillSwitch.shared.tripped, override == nil, m == .screen,
                   let up = router.escalation(from: m, settings: s) {
                    log("Retrying with \(up.rawValue)")
                    override = up
                    continue
                }
                break
            }
            history.append(("user", text))
            history.append(("assistant", outcome.summary))
            reply(outcome.summary)
        } catch is CancellationError {
            phase = .idle
        } catch {
            reply(error.localizedDescription)
        }
    }

    /// Claude first when it's set up and healthy; any failure drops straight to Gemini.
    private func runAgent(_ text: String, mode: Mode, tier: Tier, chain: [String], client: GeminiClient,
                          tools: ToolBox, settings s: JarvisSettings) async throws -> AgentOutcome {
        let logger: @Sendable (String) -> Void = { [weak self] line in Task { @MainActor in self?.log(line) } }

        // Claude has no built-in web search here, so current-events questions go to Gemini.
        if s.claudeEnabled, !store.claudeKey.isEmpty, mode != .web, Date() >= claudeBlockedUntil {
            let agent = ClaudeAgent(client: ClaudeClient(apiKey: store.claudeKey), model: s.claudeModelID(tier), settings: s,
                                    tools: tools, tracker: usage, facts: memory.facts, log: logger)
            do {
                return try await agent.run(task: text, mode: mode, history: Array(history.suffix(8)))
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as LLMError {
                if case .other = e { throw e }   // permission problems would fail on Gemini too
                if case .http(let code, _) = e, [400, 401, 402, 403].contains(code) {
                    claudeBlockedUntil = Date().addingTimeInterval(30 * 60)   // no credits or bad key: stop trying for a while
                }
                log("Claude unavailable, using Gemini.")
            } catch {
                log("Claude unavailable, using Gemini.")
            }
        }

        guard !store.geminiKey.isEmpty else {
            throw LLMError.other("Claude didn't work and there's no Gemini key. Add one in Settings.")
        }
        let agent = GeminiAgent(client: client, chain: chain, settings: s, tools: tools, tracker: usage,
                                facts: memory.facts, log: logger)
        return try await agent.run(task: text, mode: mode, history: Array(history.suffix(8)))
    }

    // MARK: Helpers

    private func askPermission(_ question: String) async -> Bool {
        speaker.say("Should I go ahead?", rate: store.value.voiceRate)
        let alert = NSAlert()
        alert.messageText = "Jarvis wants to continue"
        alert.informativeText = question
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func notify(_ title: String, _ body: String) {
        log("\(title): \(body)")
        overlayText = body
        overlayVisible = true
        if store.value.speakReplies { speaker.say(body, rate: store.value.voiceRate) }
        if bundled {
            let c = UNMutableNotificationContent()
            c.title = title
            c.body = body
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
        }
        refreshOverlay()
    }

    private func reply(_ text: String) {
        log("Jarvis: \(text)")
        overlayText = text
        phase = .idle
        if store.value.speakReplies { speaker.say(text, rate: store.value.voiceRate) }
    }

    func log(_ line: String) {
        feed.append(line)
        if feed.count > 200 { feed.removeFirst(feed.count - 200) }
    }

    private func refreshOverlay() {
        hideTask?.cancel()
        guard store.value.overlayEnabled else { overlayVisible = false; return }
        if phase != .idle {
            overlayVisible = true
        } else {
            hideTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if !Task.isCancelled { self?.overlayVisible = false }
            }
        }
    }

    /// Esc anywhere stops whatever Jarvis is doing.
    private func installKillSwitch() {
        let handler: (NSEvent) -> Void = { [weak self] e in
            if e.keyCode == 53 { Task { @MainActor in self?.stopEverything() } }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { handler($0); return $0 }) { monitors.append(l) }
    }
}
