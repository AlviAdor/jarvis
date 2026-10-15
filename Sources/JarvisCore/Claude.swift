import Foundation
import AppKit

public final class ClaudeClient: @unchecked Sendable {
    private let apiKey: String
    public init(apiKey: String) { self.apiKey = apiKey }

    public func send(_ body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw LLMError.badResponse }
        if obj["stop_reason"] as? String == "refusal" { throw LLMError.refused("") }
        return obj
    }

    public static func usage(_ obj: [String: Any]) -> Usage {
        let u = obj["usage"] as? [String: Any]
        return Usage(input: u?["input_tokens"] as? Int ?? 0, output: u?["output_tokens"] as? Int ?? 0)
    }

    public static func imageBlock(_ jpeg: Data) -> [String: Any] {
        ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": jpeg.base64EncodedString()]]
    }
}

/// Same job as GeminiAgent, run on Claude. Any failure is thrown so the caller can fall back to Gemini.
public final class ClaudeAgent: @unchecked Sendable {
    private let client: ClaudeClient
    private let model: String
    private let settings: JarvisSettings
    private let tools: ToolBox
    private let tracker: UsageTracker
    private let facts: [String]
    private let log: @Sendable (String) -> Void

    public init(client: ClaudeClient, model: String, settings: JarvisSettings, tools: ToolBox,
                tracker: UsageTracker, facts: [String], log: @escaping @Sendable (String) -> Void) {
        self.client = client
        self.model = model
        self.settings = settings
        self.tools = tools
        self.tracker = tracker
        self.facts = facts
        self.log = log
    }

    public func run(task: String, mode: Mode, history: [(role: String, text: String)]) async throws -> AgentOutcome {
        var messages: [[String: Any]] = history.map { ["role": $0.role, "content": [["type": "text", "text": $0.text]]] }
        let screenMode = mode == .screen
        let screenSize = await MainActor.run { NSScreen.main?.frame.size ?? CGSize(width: 1440, height: 900) }

        var first: [[String: Any]] = [["type": "text", "text": task]]
        if screenMode {
            try Permissions.ensureAccessibility()
            first.append(ClaudeClient.imageBlock(try Screen.capture().jpeg))
        }
        messages.append(["role": "user", "content": first])

        let system = jarvisSystemPrompt(mode: mode, settings: settings, facts: facts)
        let toolDefs = tools.anthropicTools(screen: screenMode)
        // Older screenshots can't be pruned without editing history, so keep Claude's screen runs short.
        let limit = screenMode ? min(settings.maxSteps, 15) : 6

        for step in 1...limit {
            if KillSwitch.shared.tripped { return AgentOutcome(success: false, summary: "Stopped.") }
            if await tracker.overCap(settings.dailyRequestCap) {
                return AgentOutcome(success: false, summary: "You've reached today's request limit. You can raise it in Settings.")
            }
            let obj = try await client.send([
                "model": model,
                "max_tokens": 2048,
                "system": system,
                "tools": toolDefs,
                "messages": messages,
                "cache_control": ["type": "ephemeral"],
            ])
            await tracker.add(ClaudeClient.usage(obj))

            let content = obj["content"] as? [[String: Any]] ?? []
            messages.append(["role": "assistant", "content": content])

            let calls = content.filter { $0["type"] as? String == "tool_use" }
            if calls.isEmpty {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined()
                return AgentOutcome(success: true, summary: text.isEmpty ? "Done." : text)
            }
            if obj["stop_reason"] as? String == "max_tokens" { throw LLMError.badResponse }

            var results: [[String: Any]] = []
            var wantShot = false
            for call in calls {
                let name = call["name"] as? String ?? ""
                let args = call["input"] as? [String: Any] ?? [:]
                log("\(step). \(args["intent"] as? String ?? name)")
                let res = await tools.execute(name, args, screen: screenSize)
                if let done = res.finished { return done }
                if KillSwitch.shared.tripped { return AgentOutcome(success: false, summary: "Stopped.") }
                wantShot = wantShot || (res.screenshot && screenMode)
                results.append(["type": "tool_result", "tool_use_id": call["id"] as? String ?? "",
                                "content": [["type": "text", "text": res.text.isEmpty ? "ok" : res.text]]])
            }
            if wantShot, var last = results.popLast(), var block = last["content"] as? [[String: Any]] {
                try? await Task.sleep(nanoseconds: 400_000_000)
                block.append(ClaudeClient.imageBlock(try Screen.capture().jpeg))
                last["content"] = block
                results.append(last)
            }
            messages.append(["role": "user", "content": results])
        }
        return AgentOutcome(success: false, summary: "I ran out of steps before finishing.")
    }
}
