import SwiftUI
import AppKit
import JarvisCore

enum Phase: String {
    case idle, listening, thinking, acting
}

@MainActor
final class AppModel: ObservableObject {
    let store = SettingsStore()
    let cost = CostTracker()
    let voice = VoiceInput()
    private let speaker = Speaker()
    private let router = Router()

    @Published var phase: Phase = .idle
    @Published var feed: [String] = []
    @Published var typed = ""

    private var history: [ChatTurn] = []
    private var job: Task<Void, Never>?
    private var monitors: [Any] = []

    init() {
        voice.onFinal = { [weak self] text in self?.submit(text) }
        installKillSwitch()
    }

    var accent: Color {
        switch store.value.accent {
        case "purple": return .purple
        case "green": return .green
        case "orange": return .orange
        default: return .cyan
        }
    }

    // MARK: Input

    func toggleListening() {
        if voice.listening {
            voice.finish()
            return
        }
        speaker.stop()
        Task {
            guard await VoiceInput.authorize() else {
                log("Microphone or speech permission is off. Enable it in System Settings.")
                return
            }
            do {
                try voice.start()
                phase = .listening
            } catch {
                log("Couldn't start listening: \(error.localizedDescription)")
            }
        }
    }

    func stopEverything() {
        KillSwitch.shared.trip()
        job?.cancel()
        speaker.stop()
        voice.stop()
        phase = .idle
    }

    func submit(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        typed = ""
        job?.cancel()
        job = Task { await handle(t) }
    }

    // MARK: Pipeline

    private func handle(_ text: String) async {
        phase = .thinking
        KillSwitch.shared.reset()
        cost.startTask()
        log("You: \(text)")

        let s = store.value
        let hub = Hub(claudeKey: store.claudeKey, geminiKey: store.geminiKey)
        guard !hub.available.isEmpty else {
            reply("Add an API key in Settings first.")
            return
        }
        guard cost.month < s.monthlyBudgetUSD else {
            reply("You've reached this month's spending limit. You can raise it in Settings.")
            return
        }

        do {
            var difficulty = router.heuristic(text)
            if difficulty == nil, let cheap = router.cheapest(available: hub.available, settings: s) {
                let r = try await hub.complete(cheap, system: Router.classifierPrompt, turns: [ChatTurn(role: "user", text: text)], maxTokens: 8)
                cost.add(cheap, r.usage)
                difficulty = Router.parse(r.text)
            }
            let d = difficulty ?? .chat
            guard let route = router.pick(d, available: hub.available, settings: s) else {
                reply("I don't have a model available for that.")
                return
            }
            log("\(route.model.name) · \(route.reason)")

            if d == .screen {
                try await runScreenTask(text, route: route, hub: hub)
            } else {
                try await chat(text, model: route.model, hub: hub)
            }
        } catch is CancellationError {
            phase = .idle
        } catch {
            reply("Something went wrong. \(error.localizedDescription)")
        }
    }

    private func chat(_ text: String, model: ModelSpec, hub: Hub) async throws {
        history.append(ChatTurn(role: "user", text: text))
        let system = "You are Jarvis, a voice assistant on the user's Mac. Answer in one to three short spoken sentences unless asked for more. No markdown."
        let r = try await hub.complete(model, system: system, turns: Array(history.suffix(12)), maxTokens: 1024)
        cost.add(model, r.usage)
        history.append(ChatTurn(role: "assistant", text: r.text))
        reply(r.text)
    }

    private func runScreenTask(_ text: String, route: Route, hub: Hub) async throws {
        guard let claude = hub.claude else {
            reply("Controlling the screen needs a Claude API key. Add one in Settings.")
            return
        }
        phase = .acting
        var model = route.model
        var outcome: AgentOutcome
        while true {
            let agent = ComputerAgent(
                claude: claude, model: model, settings: store.value, tracker: cost,
                confirm: { [weak self] question in await self?.askPermission(question) ?? false },
                log: { [weak self] line in Task { @MainActor in self?.log(line) } }
            )
            outcome = try await agent.run(task: text)
            // One retry on a stronger model if the first attempt gave up on its own.
            if !outcome.success, !KillSwitch.shared.tripped, store.value.modelChoice == "auto",
               let next = router.escalate(model, available: hub.available) {
                log("Retrying with \(next.name)")
                model = next
                continue
            }
            break
        }
        reply(outcome.summary)
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

    private func reply(_ text: String) {
        log("Jarvis: \(text)")
        phase = .idle
        if store.value.speakReplies { speaker.say(text, rate: store.value.voiceRate) }
    }

    func log(_ line: String) {
        feed.append(line)
        if feed.count > 200 { feed.removeFirst(feed.count - 200) }
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
