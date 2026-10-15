import XCTest
@testable import JarvisCore

final class RouterTests: XCTestCase {
    let r = Router()

    func testHeuristics() {
        XCTAssertNotEqual(r.heuristic("open Safari and go to apple.com"), .screen)   // done with app controls, not screenshots
        XCTAssertEqual(r.heuristic("what's on my screen right now"), .screen)
        XCTAssertEqual(r.heuristic("what's the weather in Dhaka"), .web)
        XCTAssertEqual(r.heuristic("how are you"), .chat)
        XCTAssertEqual(r.heuristic("analyze this strategy and compare the options for my startup in detail please"), .hard)
        XCTAssertEqual(r.heuristic("think hard about whether I should learn Rust or Go next year"), .hard)
        XCTAssertNil(r.heuristic("tell me something interesting about the history of the printing press"))
    }

    func testToolRequestsSkipTheLocalModel() {
        XCTAssertTrue(Router.needsTools("remember that my sister is called Mim"))
        XCTAssertTrue(Router.needsTools("check my email"))
        XCTAssertTrue(Router.needsTools("set a timer for ten minutes"))
        XCTAssertFalse(Router.needsTools("tell me a joke"))
        XCTAssertFalse(Router.needsTools("what is the capital of Japan"))
    }

    func testChainFallsBackToCheaperModels() {
        var s = JarvisSettings()
        XCTAssertEqual(r.chain(for: .hard, settings: s), [s.proModel, s.flashModel, s.liteModel])
        XCTAssertEqual(r.chain(for: .chat, settings: s), [s.liteModel, s.flashModel])
        s.modelChoice = "flash"
        XCTAssertEqual(r.chain(for: .hard, settings: s), [s.flashModel, s.liteModel])
        XCTAssertNil(r.escalation(from: .screen, settings: s))
    }

    func testClassifierParsing() {
        XCTAssertEqual(Router.parse("Screen"), .screen)
        XCTAssertEqual(Router.parse("hard."), .hard)
        XCTAssertEqual(Router.parse("web"), .web)
        XCTAssertEqual(Router.parse("something else"), .chat)
    }
}

final class ModelTests: XCTestCase {
    let list = [
        "gemini-2.5-flash", "gemini-2.5-pro", "gemini-3-flash-preview", "gemini-3.6-flash", "gemini-3.8-flash",
        "gemini-3.8-flash-image", "gemini-3.8-flash-tts", "gemini-3.1-flash-lite", "gemini-3.5-flash-lite",
        "gemini-3.1-pro-preview",
    ]

    func testNewestPicksHighestUsableModel() {
        XCTAssertEqual(ModelPicker.newest(.flash, in: list), "gemini-3.8-flash")
        XCTAssertEqual(ModelPicker.newest(.lite, in: list), "gemini-3.5-flash-lite")
        XCTAssertEqual(ModelPicker.newest(.pro, in: list), "gemini-3.1-pro-preview")
        XCTAssertNil(ModelPicker.newest(.pro, in: ["gemini-3.8-flash"]))
    }

    func testThinkingMatchesTheModelGeneration() {
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.8-flash", mode: .chat), .level("low"))
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.5-flash-lite", mode: .chat), .level("minimal"))
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.8-flash", mode: .hard), .level("high"))
        XCTAssertNil(GeminiAgent.thinking(for: "gemini-3.1-pro-preview", mode: .hard))
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-2.5-flash", mode: .chat), .budget(0))
    }

    func testSettingsUpgradeKeepsChoicesAndRetiresOldModels() throws {
        let saved = try JSONSerialization.data(withJSONObject: [
            "wakeWord": "friday", "flashModel": "gemini-2.5-flash", "liteModel": "my-custom-model", "removedOption": 1,
        ])
        let s = JarvisSettings.load(from: saved)
        XCTAssertEqual(s.wakeWord, "friday")
        XCTAssertEqual(s.flashModel, JarvisSettings().flashModel)
        XCTAssertEqual(s.liteModel, "my-custom-model")
        XCTAssertEqual(s.voicePitch, 1.0)
        XCTAssertEqual(JarvisSettings.load(from: nil), JarvisSettings())
    }

    func testErrorsAreFriendlyAndNeverLeakKeys() {
        let e = LLMError.http(429, #"{"error":{"message":"Quota exceeded for AIzaSyA1234567890abcdefghijklmn"}}"#)
        let m = Friendly.message(e)
        XCTAssertTrue(m.contains("limiting requests"))
        XCTAssertTrue(m.contains("Quota exceeded"))
        XCTAssertFalse(m.contains("AIza"))
        XCTAssertEqual(Redact.secrets("key sk-ant-abcdefghijklmnop here"), "key [key] here")
    }

    func testTermsCoverResponsibilityAndProviderPolicies() {
        XCTAssertTrue(Terms.text.contains("Generative AI Prohibited Use Policy"))
        XCTAssertTrue(Terms.text.contains("Usage Policy"))
        XCTAssertTrue(Terms.text.contains("solely responsible"))
        XCTAssertTrue(Terms.text.contains("18 or older"))
    }
}

final class LocalBrainTests: XCTestCase {
    func testHandOffWordsAreRecognisedEarly() {
        XCTAssertNil(LocalBrain.verdict("ESC", finished: false))
        guard case .escalate(.web)? = LocalBrain.verdict("ESCALATE_WEB", finished: false) else { return XCTFail() }
        guard case .escalate(.screen)? = LocalBrain.verdict("ESCALATE_SCREEN", finished: true) else { return XCTFail() }
        guard case .escalate(.chat)? = LocalBrain.verdict("ESCALATE_TOOLS", finished: true) else { return XCTFail() }
        guard case .answer(let a)? = LocalBrain.verdict("Every day is a good day.", finished: false) else { return XCTFail() }
        XCTAssertEqual(a, "Every day is a good day.")
        guard case .escalate? = LocalBrain.verdict("", finished: true) else { return XCTFail() }
    }

    func testReasoningTagsAreNeverSpoken() {
        XCTAssertEqual(LocalBrain.stripThinking("<think>hmm</think>Hello there"), "Hello there")
        XCTAssertEqual(LocalBrain.stripThinking("<think>still thinking"), "")
    }

    func testSmallModelsArePreferred() {
        XCTAssertEqual(LocalBrain.pickSmall(["llama3.1:70b", "llama3.2:3b", "qwen3:32b"]), "llama3.2:3b")
        XCTAssertEqual(LocalBrain.pickSmall(["custom:latest"]), "custom:latest")
        XCTAssertNil(LocalBrain.pickSmall([]))
    }
}

final class SchedulerTests: XCTestCase {
    func testNextFireIsInTheFutureAndOnTime() {
        let a = Automation(id: "x", prompt: "p", hour: 8, minute: 30, days: [])
        let now = Date()
        let next = Scheduler.nextFire(a, after: now)!
        XCTAssertGreaterThan(next, now)
        XCTAssertLessThanOrEqual(next.timeIntervalSince(now), 86_400 + 1)
        let c = Calendar.current.dateComponents([.hour, .minute], from: next)
        XCTAssertEqual(c.hour, 8)
        XCTAssertEqual(c.minute, 30)
    }

    func testWeekdayFilter() {
        let a = Automation(id: "x", prompt: "p", hour: 9, minute: 0, days: [2]) // Monday
        let next = Scheduler.nextFire(a, after: Date())!
        XCTAssertEqual(Calendar.current.component(.weekday, from: next), 2)
    }
}

final class ToolTests: XCTestCase {
    func box(_ s: JarvisSettings = JarvisSettings(), confirm: @escaping @Sendable (String) async -> Bool = { _ in true },
             events: @escaping @Sendable (ActionEvent) -> Void = { _ in }, mcp: [MCPTool] = []) -> ToolBox {
        ToolBox(settings: s, memory: MemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-memory")), confirm: confirm, notify: { _, _ in }, onAction: events, mcp: mcp)
    }

    func testAnthropicSchemaIsLowercasedAndMatchesDeclarations() {
        let b = box()
        let gem = b.declarations(screen: true)
        let ant = b.anthropicTools(screen: true)
        XCTAssertEqual(gem.count, ant.count)
        let computer = ant.first { $0["name"] as? String == "computer" }!
        let schema = computer["input_schema"] as! [String: Any]
        XCTAssertEqual(schema["type"] as? String, "object")
        let props = schema["properties"] as! [String: Any]
        XCTAssertEqual((props["x"] as! [String: Any])["type"] as? String, "integer")
    }

    func testScreenToolOnlyWhenRequested() {
        XCTAssertFalse(box().declarations(screen: false).contains { $0["name"] as? String == "computer" })
    }

    func testMCPToolsAppearForBothProviders() {
        let t = MCPTool(server: "my files", name: "read-file", description: "Reads a file",
                        schema: ["type": "object", "properties": ["path": ["type": "string"]], "required": ["path"]])
        XCTAssertEqual(t.exposedName, "mcp_my_files__read_file")
        let b = box(mcp: [t])
        let g = b.declarations(screen: false).first { $0["name"] as? String == t.exposedName }!
        let gp = g["parameters"] as! [String: Any]
        XCTAssertEqual(gp["type"] as? String, "OBJECT")
        let a = b.anthropicTools(screen: false).first { $0["name"] as? String == t.exposedName }!
        let ap = a["input_schema"] as! [String: Any]
        XCTAssertEqual(((ap["properties"] as! [String: Any])["path"] as! [String: Any])["type"] as? String, "string")
    }

    func testSchemaConversionHandlesCommonJSONSchemaShapes() {
        let s = SchemaConvert.gemini([
            "type": "object",
            "$schema": "http://json-schema.org/draft-07/schema#",
            "additionalProperties": false,
            "properties": [
                "tags": ["type": "array"],
                "mode": ["anyOf": [["type": "null"], ["type": "string", "enum": ["a", "b"]]]],
                "count": ["type": ["integer", "null"]],
            ],
            "required": ["tags", "missing"],
        ])
        XCTAssertNil(s["$schema"])
        XCTAssertNil(s["additionalProperties"])
        let p = s["properties"] as! [String: Any]
        XCTAssertEqual(((p["tags"] as! [String: Any])["items"] as! [String: Any])["type"] as? String, "STRING")
        XCTAssertEqual((p["mode"] as! [String: Any])["enum"] as? [String], ["a", "b"])
        XCTAssertEqual((p["count"] as! [String: Any])["type"] as? String, "INTEGER")
        XCTAssertEqual(s["required"] as? [String], ["tags"])
    }

    func testPruneKeepsOnlyNewestScreenshotsAndMaps() {
        func shot() -> [String: Any] {
            ["role": "user", "parts": [["functionResponse": ["name": "computer",
                                                            "response": ["result": "Clicked.\(ScreenReader.marker) Safari\nbutton \"OK\" @ 1,2"],
                                                            "parts": [["inlineData": ["data": "x"]]]]]]]
        }
        var contents = [shot(), shot(), shot(), shot()]
        GeminiAgent.pruneImages(&contents, keep: 2)
        let fr = ((contents[0]["parts"] as! [[String: Any]])[0]["functionResponse"] as! [String: Any])
        XCTAssertNil(fr["parts"])
        XCTAssertEqual((fr["response"] as! [String: Any])["result"] as? String, "Clicked.")
        let newest = ((contents[3]["parts"] as! [[String: Any]])[0]["functionResponse"] as! [String: Any])
        XCTAssertNotNil(newest["parts"])
    }

    func testScreenshotsCanBeMovedOutOfFunctionResponses() {
        var contents: [[String: Any]] = [["role": "user", "parts": [["functionResponse": [
            "name": "computer", "response": ["result": "ok"],
            "parts": [["inlineData": ["mimeType": "image/jpeg", "data": "abc"]]],
        ]]]]]
        GeminiAgent.moveImagesOut(&contents)
        let parts = contents[0]["parts"] as! [[String: Any]]
        XCTAssertEqual(parts.count, 2)
        XCTAssertNil((parts[0]["functionResponse"] as! [String: Any])["parts"])
        XCTAssertEqual((parts[1]["inline_data"] as! [String: Any])["data"] as? String, "abc")
        XCTAssertTrue(GeminiAgent.looksLikeImagePlacement("Invalid value at 'contents[3].parts[0].function_response'"))
    }

    func testFileAccessIsLimitedToAllowedFolders() async {
        var s = JarvisSettings()
        s.allowedFolders = [NSTemporaryDirectory()]
        let denied = await box(s).execute("read_file", ["path": "/etc/hosts"], screen: .zero)
        XCTAssertTrue(denied.text.contains("allowed"))
    }

    func testEveryStepIsReportedLive() async {
        let log = EventLog()
        _ = await box(events: { log.add($0) }).execute("list_schedules", [:], screen: .zero)
        XCTAssertEqual(log.events.map(\.state), [.running, .done])
        XCTAssertEqual(log.events.first?.title, "Checking your automations")
    }

    func testUntrustedContentForcesConfirmation() async {
        let asked = EventLog()
        let b = box(confirm: { q in asked.note(q); return false })
        _ = await b.execute("clipboard_read", [:], screen: .zero)
        let r = await b.execute("open_url", ["url": "https://example.com/?q=secret"], screen: .zero)
        XCTAssertEqual(r.text, "The user declined.")
        XCTAssertEqual(asked.questions.count, 1)
    }
}

final class MCPTests: XCTestCase {
    /// A tiny stdio tool server, so the client is tested end to end without network or Node.
    static let fakeServer = #"""
    import sys, json
    for line in sys.stdin:
        m = json.loads(line)
        if "id" not in m:
            continue
        meth, i = m.get("method"), m["id"]
        if meth == "initialize":
            r = {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "fake", "version": "1"}}
        elif meth == "tools/list":
            r = {"tools": [{"name": "echo", "description": "Echo text back", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}
        elif meth == "tools/call":
            r = {"content": [{"type": "text", "text": "echo: " + m["params"]["arguments"]["text"]}]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": i, "error": {"code": -32601, "message": "nope"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": i, "result": r}), flush=True)
    """#

    func testClientListsAndCallsTools() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let script = dir.appendingPathComponent("server.py")
        try Self.fakeServer.write(to: script, atomically: true, encoding: .utf8)

        let hub = MCPHub()
        defer { hub.stopAll() }
        let cfg = MCPServerConfig(id: "fake", command: "python3", args: ["-u", script.path])
        let tools = await hub.tools(for: [cfg], log: { _ in })
        XCTAssertEqual(tools.map(\.name), ["echo"])
        let out = await hub.call(tools[0], ["text": "hello"])
        XCTAssertEqual(out, "echo: hello")
    }
}

final class VoiceMatchTests: XCTestCase {
    func testEnrolledVoiceMatchesItselfButNotADifferentOne() {
        var rng = SystemRandomNumberGenerator()
        let me = (0..<48).map { _ in Float.random(in: -1...1, using: &rng) }
        let other = (0..<48).map { _ in Float.random(in: -1...1, using: &rng) }
        func noisy(_ v: [Float]) -> [Float] { v.map { $0 + Float.random(in: -0.08...0.08) } }
        let profile = VoiceProfile.enroll((0..<5).map { _ in noisy(me) })!
        XCTAssertTrue(profile.matches(noisy(me), strictness: 0.5))
        XCTAssertFalse(profile.matches(other, strictness: 0.5))
        XCTAssertNil(VoiceProfile.enroll([me, me]))
    }
}

final class SandboxTests: XCTestCase {
    func testNetworkIsBlocked() async {
        let out = await Sandbox.run("curl -s -m 5 https://example.com && echo REACHED || echo BLOCKED")
        XCTAssertTrue(out.contains("BLOCKED"), out)
    }

    func testWritesOutsideScratchAreBlocked() async {
        let target = NSHomeDirectory() + "/jarvis-sandbox-test-\(UUID().uuidString)"
        let out = await Sandbox.run("touch '\(target)' && echo WROTE || echo DENIED")
        XCTAssertTrue(out.contains("DENIED"), out)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target))
    }

    func testScratchIsWritableAndCredentialsAreHidden() async {
        let ok = await Sandbox.run("echo hi > note.txt && cat note.txt")
        XCTAssertTrue(ok.contains("hi"), ok)
        let ssh = await Sandbox.run("ls ~/.ssh 2>&1 | head -1")
        XCTAssertTrue(ssh.contains("Operation not permitted") || ssh.contains("No such file"), ssh)
    }
}

/// Thread-safe recorder for callbacks in tests.
final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [ActionEvent] = []
    private var _questions: [String] = []
    var events: [ActionEvent] { lock.withLock { _events } }
    var questions: [String] { lock.withLock { _questions } }
    func add(_ e: ActionEvent) { lock.withLock { _events.append(e) } }
    func note(_ q: String) { lock.withLock { _questions.append(q) } }
}
