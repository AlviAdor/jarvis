import Foundation
import AppKit

/// Screen tasks with Gemini's built-in computer use: the model looks at the screen and answers with
/// actions (click, type, scroll, drag, keys) that Jarvis performs on the real Mac, visibly, one at a time.
/// Jarvis's own tools stay available alongside, and Gemini's own safety checks ask the user first.
public final class ComputerUseAgent: @unchecked Sendable {
    private let key: String
    private let model: String
    private let settings: JarvisSettings
    private let tools: ToolBox
    private let tracker: UsageTracker
    private let profile: String
    private let log: @Sendable (String) -> Void

    /// Models Google lists as supporting computer use.
    public static let supported = ["gemini-4-argon", "gemini-3.8-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite"]
    /// Jarvis tools offered next to the screen actions.
    static let helpers: Set<String> = ["open_app", "open_url", "ui", "run_applescript", "browser", "files", "mac_control",
                                       "clipboard_read", "clipboard_write", "web_search", "fetch_url"]
    static let actions: Set<String> = ["click", "double_click", "triple_click", "middle_click", "right_click", "mouse_down", "mouse_up",
                                       "move", "type", "drag_and_drop", "wait", "press_key", "key_down", "key_up", "hotkey",
                                       "take_screenshot", "scroll"]

    public init(key: String, model: String, settings: JarvisSettings, tools: ToolBox, tracker: UsageTracker,
                profile: String, log: @escaping @Sendable (String) -> Void) {
        self.key = key
        self.model = model
        self.settings = settings
        self.tools = tools
        self.tracker = tracker
        self.profile = profile
        self.log = log
    }

    /// The best supported model this key has: the strongest at Max effort, otherwise the main Flash model.
    public static func pick(_ s: JarvisSettings) -> String? {
        let known = Set(s.knownModels)
        var order = [s.flashModel, "gemini-3.8-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite"]
        if s.effectiveEffort == "max" { order.insert("gemini-4-argon", at: 0) }
        return order.first { supported.contains($0) && (known.isEmpty || known.contains($0)) && QuotaBook.shared.usable($0) }
    }

    private func post(_ body: [String: Any]) async throws -> [String: Any] {
        guard QuotaBook.shared.usable(model) else { throw LLMError.http(429, #"{"error":{"message":"resting"}}"#) }
        var req = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        req.httpMethod = "POST"
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 120
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let text = String(data: data, encoding: .utf8) ?? ""
        if code == 429 { QuotaBook.shared.note(model, body: text) }
        guard code == 200, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.http(code, text) }
        return obj
    }

    private static func image(_ shot: Shot) -> [String: Any] {
        ["type": "image", "data": shot.jpeg.base64EncodedString(), "mime_type": "image/jpeg"]
    }

    public func run(task: String, history: [(role: String, text: String)]) async throws -> AgentOutcome {
        try Permissions.ensureAccessibility()
        let screen = await MainActor.run { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }
        var shot = try await Screen.capture()
        let recent = history.suffix(4).map { "\($0.role == "user" ? "User" : "Jarvis"): \($0.text.prefix(300))" }.joined(separator: "\n")
        let ask = (recent.isEmpty ? "" : "Conversation so far:\n\(recent)\n\n") + "Task: \(task)"
        let helpers: [[String: Any]] = tools.anthropicTools(screen: false).compactMap { t in
            guard let name = t["name"] as? String, Self.helpers.contains(name) else { return nil }
            return ["type": "function", "name": name, "description": t["description"] ?? "", "parameters": t["input_schema"] ?? [:]]
        }
        var body: [String: Any] = [
            "model": model,
            "system_instruction": jarvisSystemPrompt(mode: .screen, settings: settings, profile: profile),
            "input": [["type": "user_input", "content": [["type": "text", "text": ask], Self.image(shot)]]],
            "tools": [["type": "computer_use", "environment": "desktop", "enable_prompt_injection_detection": true]] + helpers,
        ]

        for _ in 1...max(1, settings.maxSteps) {
            if KillSwitch.shared.tripped { return AgentOutcome(success: false, summary: "Stopped.") }
            if await tracker.overCap(settings.dailyRequestCap) {
                return AgentOutcome(success: false, summary: "You've reached today's request limit. You can raise it in Settings.")
            }
            let obj = try await post(body)
            await tracker.add(Usage())
            let steps = obj["steps"] as? [[String: Any]] ?? []
            let calls = steps.filter { $0["type"] as? String == "function_call" }
            let said = steps.filter { $0["type"] as? String == "model_output" }
                .flatMap { $0["content"] as? [[String: Any]] ?? [] }
                .compactMap { $0["text"] as? String }.joined()
            if calls.isEmpty { return AgentOutcome(success: true, summary: said.isEmpty ? "Done." : said) }

            var results: [(name: String, id: String, result: [String: Any])] = []
            for call in calls {
                let name = call["name"] as? String ?? ""
                let args = call["arguments"] as? [String: Any] ?? [:]
                let id = call["id"] as? String ?? call["call_id"] as? String ?? ""
                var result: [String: Any] = [:]
                if let safety = args["safety_decision"] as? [String: Any], safety["decision"] as? String == "require_confirmation" {
                    let why = safety["explanation"] as? String ?? "This step needs your OK."
                    guard await tools.ask(why) else { return AgentOutcome(success: false, summary: "Okay, I stopped there.") }
                    result["safety_acknowledgement"] = true
                }
                if Self.actions.contains(name) {
                    result["result"] = await perform(name, args, screen: screen)
                } else {
                    let r = await tools.execute(name, args, screen: screen)
                    if let done = r.finished { return done }
                    result["result"] = r.text
                }
                if KillSwitch.shared.tripped { return AgentOutcome(success: false, summary: "Stopped.") }
                result["url"] = ""
                results.append((name, id, result))
            }
            try? await Task.sleep(nanoseconds: 300_000_000)
            shot = try await Screen.capture()
            // One fresh screenshot per turn, on the last result, keeps each step light.
            body["input"] = results.enumerated().map { i, r -> [String: Any] in
                let json = (try? JSONSerialization.data(withJSONObject: r.result)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
                var parts: [[String: Any]] = [["type": "text", "text": json]]
                if i == results.count - 1 { parts.append(Self.image(shot)) }
                return ["type": "function_result", "name": r.name, "call_id": r.id, "result": parts]
            }
            if let id = obj["id"] as? String { body["previous_interaction_id"] = id }
        }
        return AgentOutcome(success: false, summary: "I ran out of steps before finishing.")
    }

    static func keyName(_ k: String) -> String {
        switch k.lowercased() {
        case "control", "ctrl": return "ctrl"
        case "command", "cmd", "meta", "super": return "cmd"
        case "option", "alt": return "alt"
        case "enter": return "return"
        case "arrowup", "up": return "up"
        case "arrowdown", "down": return "down"
        case "arrowleft", "left": return "left"
        case "arrowright", "right": return "right"
        case "backspace": return "delete"
        default: return k.lowercased()
        }
    }

    /// Carries out one screen action on the real Mac and shows it in the activity list.
    func perform(_ name: String, _ a: [String: Any], screen: CGSize) async -> String {
        func n(_ k: String) -> Double? { (a[k] as? Double) ?? (a[k] as? Int).map(Double.init) }
        func point(_ xk: String = "x", _ yk: String = "y") -> CGPoint? {
            guard let x = n(xk), let y = n(yk) else { return nil }
            return CGPoint(x: min(max(x, 0), 999) / 1000 * screen.width, y: min(max(y, 0), 999) / 1000 * screen.height)
        }
        let intent = (a["intent"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? name.replacingOccurrences(of: "_", with: " ").capitalized
        let p = point()
        let id = UUID()
        let icon = name == "type" || name.contains("key") ? "keyboard" : name == "scroll" ? "scroll" : name == "wait" ? "hourglass" : "cursorarrow.click.2"
        tools.report(ActionEvent(id: id, title: intent, detail: name == "type" ? a["text"] as? String : nil, point: p, state: .running, icon: icon))
        var outcome = "ok"
        switch name {
        case "click", "middle_click": if let p { await Input.click(at: p) } else { outcome = "missing x/y" }
        case "double_click": if let p { await Input.click(at: p, count: 2) } else { outcome = "missing x/y" }
        case "triple_click": if let p { await Input.click(at: p, count: 3) } else { outcome = "missing x/y" }
        case "right_click": if let p { await Input.click(at: p, right: true) } else { outcome = "missing x/y" }
        case "move": if let p { await Input.move(to: p) }
        case "mouse_down", "mouse_up":
            if let p { await Input.move(to: p); Input.button(down: name == "mouse_down", at: p) }
        case "type":
            await Input.type(a["text"] as? String ?? "")
            if a["press_enter"] as? Bool == true { _ = await Input.key("return") }
        case "drag_and_drop":
            if let from = point("start_x", "start_y"), let to = point("end_x", "end_y") { await Input.drag(from: from, to: to) } else { outcome = "missing coordinates" }
        case "wait":
            try? await Task.sleep(nanoseconds: UInt64(min(max(n("seconds") ?? 1, 0.2), 5) * 1_000_000_000))
        case "press_key", "key_down", "key_up":
            let ok = await Input.key(Self.keyName(a["key"] as? String ?? ""))
            if !ok { outcome = "unknown key" }
        case "hotkey":
            let keys = (a["keys"] as? [String] ?? []).map(Self.keyName).joined(separator: "+")
            let ok = await Input.key(keys)
            if !ok { outcome = "unknown keys" }
        case "scroll":
            if let p { await Input.move(to: p, duration: 0.15) }
            let lines = max(1, Int((n("magnitude_in_pixels") ?? 300) / 40))
            switch (a["direction"] as? String ?? "down").lowercased() {
            case "up": Input.scroll(dy: lines)
            case "left": Input.scroll(dy: 0, dx: lines)
            case "right": Input.scroll(dy: 0, dx: -lines)
            default: Input.scroll(dy: -lines)
            }
        default: break   // take_screenshot: the next turn carries one anyway
        }
        tools.report(ActionEvent(id: id, title: intent, detail: nil, point: nil, state: outcome == "ok" ? .done : .failed, icon: icon))
        return outcome
    }
}
