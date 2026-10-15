import XCTest
@testable import JarvisCore

final class RouterTests: XCTestCase {
    let r = Router()

    func testHeuristics() {
        XCTAssertEqual(r.heuristic("open Safari and go to apple.com"), .screen)
        XCTAssertEqual(r.heuristic("what's the weather in Dhaka"), .web)
        XCTAssertEqual(r.heuristic("how are you"), .chat)
        XCTAssertEqual(r.heuristic("analyze this strategy and compare the options for my startup in detail please"), .hard)
        XCTAssertNil(r.heuristic("tell me something interesting about the history of the printing press"))
    }

    func testChainFallsBackToCheaperModels() {
        var s = JarvisSettings()
        XCTAssertEqual(r.chain(for: .hard, settings: s), [s.proModel, s.flashModel, s.liteModel])
        XCTAssertEqual(r.chain(for: .chat, settings: s), [s.liteModel])
        s.modelChoice = "flash"
        XCTAssertEqual(r.chain(for: .hard, settings: s), [s.flashModel, s.liteModel])
        XCTAssertNil(r.escalation(from: .screen, settings: s))
    }

    func testClassifierParsing() {
        XCTAssertEqual(Router.parse("Screen"), .screen)
        XCTAssertEqual(Router.parse("hard."), .hard)
        XCTAssertEqual(Router.parse("something else"), .chat)
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
    func testAnthropicSchemaIsLowercasedAndMatchesDeclarations() {
        let box = ToolBox(settings: JarvisSettings(), memory: MemoryStore(), confirm: { _ in true }, notify: { _, _ in })
        let gem = box.declarations(screen: true)
        let ant = box.anthropicTools(screen: true)
        XCTAssertEqual(gem.count, ant.count)
        let computer = ant.first { $0["name"] as? String == "computer" }!
        let schema = computer["input_schema"] as! [String: Any]
        XCTAssertEqual(schema["type"] as? String, "object")
        let props = schema["properties"] as! [String: Any]
        XCTAssertEqual((props["x"] as! [String: Any])["type"] as? String, "integer")
    }

    func testScreenToolOnlyWhenRequested() {
        let box = ToolBox(settings: JarvisSettings(), memory: MemoryStore(), confirm: { _ in true }, notify: { _, _ in })
        XCTAssertFalse(box.declarations(screen: false).contains { $0["name"] as? String == "computer" })
    }

    func testPruneKeepsOnlyNewestScreenshots() {
        func shot() -> [String: Any] { ["role": "user", "parts": [["inline_data": ["data": "x"]]]] }
        var contents = [shot(), shot(), shot(), shot()]
        GeminiAgent.pruneImages(&contents, keep: 2)
        let remaining = contents.filter { ($0["parts"] as! [[String: Any]]).contains { $0["inline_data"] != nil } }
        XCTAssertEqual(remaining.count, 2)
    }

    func testFileAccessIsLimitedToAllowedFolders() async {
        var s = JarvisSettings()
        s.allowedFolders = [NSTemporaryDirectory()]
        let box = ToolBox(settings: s, memory: MemoryStore(), confirm: { _ in true }, notify: { _, _ in })
        let denied = await box.execute("read_file", ["path": "/etc/hosts"], screen: .zero)
        XCTAssertTrue(denied.text.contains("allowed"))
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
