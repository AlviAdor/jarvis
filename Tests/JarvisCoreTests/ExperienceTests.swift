import XCTest
@testable import JarvisCore

final class ErrorRecoveryTests: XCTestCase {
    func testErrorsAreClassified() {
        XCTAssertEqual(ErrorKind.of(LLMError.http(429, "")), .quota)
        XCTAssertEqual(ErrorKind.of(LLMError.http(401, "")), .auth)
        XCTAssertEqual(ErrorKind.of(LLMError.http(404, "")), .modelMissing)
        XCTAssertEqual(ErrorKind.of(LLMError.http(503, "")), .server)
        XCTAssertEqual(ErrorKind.of(LLMError.refused("SAFETY")), .refused)
        XCTAssertEqual(ErrorKind.of(LLMError.other("needs Accessibility")), .permission)
        XCTAssertEqual(ErrorKind.of(URLError(.notConnectedToInternet)), .network)
        XCTAssertEqual(ErrorKind.of(URLError(.timedOut)), .timeout)
    }

    func testRecoveryRetriesOnceThenFallsBack() {
        XCTAssertEqual(Recovery.plan(.network, attempt: 0), .retry(after: 1.5))
        XCTAssertEqual(Recovery.plan(.network, attempt: 1), .local)
        XCTAssertEqual(Recovery.plan(.server, attempt: 1), .nextModel)
        XCTAssertEqual(Recovery.plan(.quota, attempt: 0), .nextModel)
        guard case .tellUser(let msg) = Recovery.plan(.auth, attempt: 0) else { return XCTFail() }
        XCTAssertTrue(msg.contains("Settings"))
    }
}

final class VerifierTests: XCTestCase {
    func testReadsPlainAndWrappedJSON() {
        let a = Verifier.parse(#"{"done": true, "reason": "Safari shows apple.com", "lesson": ""}"#)
        XCTAssertTrue(a.done)
        XCTAssertNil(a.lesson)
        let b = Verifier.parse("```json\n{\"done\": false, \"reason\": \"The file wasn't saved\", \"lesson\": \"Press cmd+s and confirm the dialog.\"}\n```")
        XCTAssertFalse(b.done)
        XCTAssertEqual(b.reason, "The file wasn't saved")
        XCTAssertEqual(b.lesson, "Press cmd+s and confirm the dialog.")
        XCTAssertTrue(Verifier.parse(#"{"done": "true", "reason": "ok"}"#).done)
    }

    func testUnreadableReplyNeverCountsAsSuccess() {
        XCTAssertFalse(Verifier.parse("I think maybe").done)
        XCTAssertFalse(Verifier.parse("").done)
    }

    func testOnlyActionsAreChecked() {
        XCTAssertTrue(Verifier.needsCheck(mode: .screen, stepTitles: []))
        XCTAssertTrue(Verifier.needsCheck(mode: .chat, stepTitles: ["Running in Terminal"]))
        XCTAssertTrue(Verifier.needsCheck(mode: .chat, stepTitles: ["Searching the web", "Saving notes.md"]))
        XCTAssertFalse(Verifier.needsCheck(mode: .chat, stepTitles: ["Searching the web", "Reading report.pdf"]))
        XCTAssertFalse(Verifier.needsCheck(mode: .web, stepTitles: []))
    }
}

final class ExperienceLogTests: XCTestCase {
    func testLessonsAreMatchedToSimilarTasks() {
        let log = ExperienceLog(file: nil)
        log.learn("Open Spotify with open_app instead of Spotlight; Spotlight search was unreliable.", about: "play my focus playlist on Spotify")
        log.learn("Save files to Documents before reporting success.", about: "write a report about solar panels")
        let hits = log.relevant(to: "play some jazz on spotify")
        XCTAssertEqual(hits.count, 1)
        XCTAssertTrue(hits[0].text.contains("Spotify"))
        XCTAssertEqual(log.lessons.first { $0.id == hits[0].id }?.uses, 1)
        XCTAssertTrue(log.relevant(to: "what's 2 plus 2").isEmpty)
        XCTAssertTrue(log.context(for: "spotify playlist").contains("Lessons from your past tasks"))
    }

    func testDuplicateLessonsAreMergedAndJunkIgnored() {
        let log = ExperienceLog(file: nil)
        log.learn("Use cmd+s to save in TextEdit.", about: "save note in textedit")
        log.learn("use cmd+s to save in TextEdit.", about: "save todo list")
        log.learn("short", about: "x")
        XCTAssertEqual(log.lessons.count, 1)
        XCTAssertTrue(log.lessons[0].keywords.contains("todo"))
        log.forget(log.lessons[0].id)
        XCTAssertTrue(log.lessons.isEmpty)
    }

    func testFailingModelsMoveToTheBack() {
        let log = ExperienceLog(file: nil)
        for _ in 0..<3 { log.noteFailure(model: "flash") }
        XCTAssertEqual(log.reorder(["flash", "lite", "pro"]), ["lite", "pro", "flash"])
        log.noteFailure(model: "lite")
        XCTAssertEqual(log.reorder(["lite", "pro"]), ["lite", "pro"])
    }

    func testEverythingSurvivesARestart() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-exp-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let a = ExperienceLog(file: file)
        a.learn("Wait for the page to load before clicking.", about: "book a table online")
        a.record(Episode(date: Date(), task: "book a table", mode: "screen", provider: "Gemini", success: true,
                         verified: true, error: nil, steps: 7, seconds: 31))
        a.record(Episode(date: Date(), task: "send mail", mode: "chat", provider: "Gemini", success: false,
                         verified: nil, error: .quota, steps: 0, seconds: 2))
        let b = ExperienceLog(file: file)
        XCTAssertEqual(b.lessons.count, 1)
        XCTAssertEqual(b.episodes.count, 2)
        let st = b.stats
        XCTAssertEqual(st.tasks, 2)
        XCTAssertEqual(st.succeeded, 1)
        XCTAssertEqual(st.verified, 1)
        XCTAssertEqual(st.checked, 1)
        b.forgetAll()
        XCTAssertTrue(ExperienceLog(file: file).episodes.isEmpty)
    }
}

final class EchoTests: XCTestCase {
    func testOwnGreetingIsNotTakenAsARequest() {
        let said = "Good morning, Alvi. How can I assist you today?"
        XCTAssertTrue(Hearing.isEcho("Morning", of: said, justSpoke: true))
        XCTAssertTrue(Hearing.isEcho("good morning", of: said, justSpoke: true))
        XCTAssertFalse(Hearing.isEcho("Morning", of: said, justSpoke: false))
    }

    func testRealRepliesRightAfterJarvisSpeaksGetThrough() {
        let asked = "Should I go ahead? Say yes or stop."
        XCTAssertFalse(Hearing.isEcho("yes", of: asked, justSpoke: true))
        XCTAssertFalse(Hearing.isEcho("stop", of: asked, justSpoke: true))
        XCTAssertFalse(Hearing.isEcho("open Safari", of: asked, justSpoke: true))
    }
}
