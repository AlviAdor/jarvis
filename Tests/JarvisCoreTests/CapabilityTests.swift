import XCTest
import AppKit
import ImageIO
import AVFoundation
@testable import JarvisCore

final class RoutingTests: XCTestCase {
    func testMacQuestionsAreRecognised() {
        XCTAssertTrue(Router.isMacStatus("how's my battery doing"))
        XCTAssertTrue(Router.isMacStatus("why is my mac so slow"))
        XCTAssertTrue(Router.isMacStatus("how much space is left on my disk"))
        XCTAssertFalse(Router.isMacStatus("free up some disk space"))
        XCTAssertFalse(Router.isMacStatus("tell me a joke"))
    }

    func testEverydayJobsUseTools() {
        for t in ["play some jazz", "what's on my calendar tomorrow", "turn the volume down", "organise my downloads",
                  "free up some disk space", "send a message to Mim", "switch to dark mode", "open Safari"] {
            XCTAssertTrue(Router.needsTools(t), t)
        }
        XCTAssertEqual(Router().heuristic("open Safari"), .chat)
        XCTAssertNotEqual(Router().heuristic("play some jazz"), .screen)
    }
}

final class MacCareTests: XCTestCase {
    func snapshot(battery: Int = 80, onAC: Bool = false, free: Int64 = 200_000_000_000, pressure: String = "normal", thermal: String = "nominal") -> MacSnapshot {
        MacSnapshot(cpu: 0.2, memoryUsed: 8 << 30, memoryTotal: 16 << 30, swapUsed: 0, pressure: pressure,
                    diskFree: free, diskTotal: 500_000_000_000,
                    battery: .init(percent: battery, charging: false, onAC: onAC, minutesLeft: 120, cycles: 300, healthPercent: 91, condition: "Good", temperatureC: 31),
                    thermal: thermal, uptime: 90_000, wifiOn: true, wifiSignal: -55, online: true)
    }

    func testAlertsOnlyForRealProblems() {
        XCTAssertTrue(SystemMonitor.alerts(snapshot()).isEmpty)
        XCTAssertEqual(SystemMonitor.alerts(snapshot(battery: 9)).count, 1)
        XCTAssertTrue(SystemMonitor.alerts(snapshot(battery: 9, onAC: true)).isEmpty)
        XCTAssertEqual(SystemMonitor.alerts(snapshot(free: 4_000_000_000)).count, 1)
        XCTAssertEqual(SystemMonitor.alerts(snapshot(pressure: "critical", thermal: "serious")).count, 2)
    }

    func testReportCoversEachArea() {
        let r = SystemMonitor.report(snapshot(), focus: "all")
        for word in ["CPU", "Memory", "Storage", "Battery", "Network", "91%", "300 cycles"] { XCTAssertTrue(r.contains(word), word) }
        XCTAssertFalse(SystemMonitor.report(snapshot(), focus: "battery").contains("Memory:"))
    }

    func testLiveSnapshotIsSane() {
        let s = SystemMonitor.shared.snapshot()
        XCTAssertGreaterThan(s.memoryTotal, 0)
        XCTAssertGreaterThan(s.diskTotal, 0)
        XCTAssert((0...1).contains(s.cpu))
        XCTAssertGreaterThan(s.uptime, 0)
    }

    func testOnlyUserFilesCanBeTrashed() {
        let home = NSHomeDirectory()
        XCTAssertTrue(DiskCare.canTrash(home + "/Downloads/old.dmg"))
        XCTAssertTrue(DiskCare.canTrash("~/Movies/clip.mov"))
        XCTAssertFalse(DiskCare.canTrash(home + "/Downloads"))
        XCTAssertFalse(DiskCare.canTrash(home + "/Library/Preferences/x.plist"))
        XCTAssertFalse(DiskCare.canTrash(home + "/.ssh/id_ed25519"))
        XCTAssertFalse(DiskCare.canTrash(home + "/Pictures/Photos Library.photoslibrary/database"))
        XCTAssertFalse(DiskCare.canTrash("/Applications/Safari.app"))
        XCTAssertFalse(DiskCare.canTrash(home + "/Documents/../Library/Keychains/login.keychain-db"))
    }

    func testOrganiserSortsAndUndoes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-organise-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        Organizer.undoOverride = dir.appendingPathComponent(".undo.json")
        defer { Organizer.undoOverride = nil }
        for name in ["photo.JPG", "report.pdf", "Setup.dmg", "Screenshot 2026-10-15 at 10.00.png", "notes.txt", "half.crdownload", "mystery"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Projects"), withIntermediateDirectories: true)

        let plan = Organizer.plan(dir)
        XCTAssertEqual(plan.moves.count, 6)   // the unfinished download and the folder stay put
        XCTAssertEqual(plan.counts["Images"], 1)
        XCTAssertEqual(plan.counts["Screenshots"], 1)
        XCTAssertEqual(plan.counts["Installers"], 1)
        XCTAssertEqual(Organizer.apply(plan), 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("PDFs/report.pdf").path))
        XCTAssertTrue(Organizer.plan(dir).moves.isEmpty)

        XCTAssertEqual(Organizer.undo(), 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("report.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("PDFs").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Projects").path))
    }

    func testOrganiserStaysOutOfLibrary() {
        XCTAssertNil(Organizer.allowed("~/Library/Caches"))
        XCTAssertNil(Organizer.allowed("/tmp"))
        XCTAssertNil(Organizer.allowed(NSHomeDirectory()))
    }

    func testDuplicatesAreFoundByContent() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-dupes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = Data(repeating: 7, count: 200_000), b = Data(repeating: 8, count: 200_000)
        try a.write(to: dir.appendingPathComponent("one.bin"))
        try a.write(to: dir.appendingPathComponent("copy of one.bin"))
        try b.write(to: dir.appendingPathComponent("same size, different.bin"))
        let groups = DiskCare.duplicates(in: dir)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.count, 2)
    }
}

final class ReadingTests: XCTestCase {
    func testWebPagesBecomeReadableText() {
        let html = """
        <html><head><title>Launch day</title><style>.x{color:red}</style><script>alert('hi')</script></head>
        <body><nav>Menu</nav><h1>Big news</h1><p>The &amp; sign &mdash; and more.</p><footer>Legal</footer></body></html>
        """
        let t = Web.readable(html)
        XCTAssertTrue(t.hasPrefix("Title: Launch day"))
        XCTAssertTrue(t.contains("Big news"))
        XCTAssertTrue(t.contains("The & sign \u{2014} and more."))
        for gone in ["alert", "color:red", "Menu", "Legal"] { XCTAssertFalse(t.contains(gone), gone) }
    }

    func testDatesInCommonShapes() {
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 9))!
        let c = { (d: Date?) in d.map { Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: $0) } }
        XCTAssertEqual(c(Agenda.parse("2026-10-16 14:30"))?.hour, 14)
        XCTAssertEqual(c(Agenda.parse("2026-10-16T08:05"))?.minute, 5)
        XCTAssertEqual(c(Agenda.parse("18:45", relativeTo: base))?.day, 15)
        XCTAssertEqual(c(Agenda.parse("2026-12-01"))?.month, 12)
        XCTAssertNil(Agenda.parse("next tuesday-ish"))
    }

    func testDocumentsAreReadAsText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-\(UUID().uuidString).rtf")
        defer { try? FileManager.default.removeItem(at: url) }
        let rtf = NSAttributedString(string: "Quarterly plan: ship Jarvis.")
        try rtf.rtf(from: NSRange(location: 0, length: rtf.length), documentAttributes: [:])?.write(to: url)
        XCTAssertEqual(Files.text(of: url)?.trimmingCharacters(in: .whitespacesAndNewlines), "Quarterly plan: ship Jarvis.")
    }
}

final class NewToolTests: XCTestCase {
    func box(_ s: JarvisSettings = JarvisSettings(), confirm: @escaping @Sendable (String) async -> Bool = { _ in true }) -> ToolBox {
        ToolBox(settings: s, memory: MemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-memory")), confirm: confirm, notify: { _, _ in },
                search: { q in "results for \(q)" }, setSetting: { n, v in "set \(n)=\(v)" })
    }

    func testEveryCapabilityIsOffered() {
        let names = Set(box().declarations(screen: false).compactMap { $0["name"] as? String })
        for n in ["mac_status", "disk", "organize_folder", "calendar", "reminders", "contacts_search", "notes", "send_message",
                  "mac_control", "shortcuts", "find_files", "open_file", "web_search", "fetch_url", "type_text",
                  "update_setting", "today_brief", "quit_app", "forget", "use_screen"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertFalse(box().declarations(screen: true).contains { $0["name"] as? String == "use_screen" })
    }

    func testSwitchedOffToolsDisappear() {
        var s = JarvisSettings()
        s.cleanupEnabled = false
        s.messagesEnabled = false
        let names = Set(box(s).declarations(screen: false).compactMap { $0["name"] as? String })
        XCTAssertFalse(names.contains("disk"))
        XCTAssertFalse(names.contains("send_message"))
    }

    func testScreenHandOff() async {
        let r = await box().execute("use_screen", ["reason": "needs clicking"], screen: .zero)
        XCTAssertEqual(r.finished?.needsScreen, true)
    }

    func testDestructiveJobsAskFirst() async {
        let asked = EventLog()
        let b = box(confirm: { q in asked.note(q); return false })
        let r1 = await b.execute("disk", ["action": "clean", "target": "caches"], screen: .zero)
        XCTAssertTrue(r1.text.contains("declined"))
        let r2 = await b.execute("send_message", ["to": "+8801", "text": "hi"], screen: .zero)
        XCTAssertTrue(r2.text.contains("declined"))
        let r3 = await b.execute("disk", ["action": "trash", "paths": NSHomeDirectory() + "/Library/Preferences/x.plist"], screen: .zero)
        XCTAssertTrue(r3.text.contains("None of those"))
        XCTAssertEqual(asked.questions.count, 2)
    }

    func testSearchAndSettingsReachTheApp() async {
        let r = await box().execute("web_search", ["query": "swift 7"], screen: .zero)
        XCTAssertEqual(r.text, "results for swift 7")
        let s = await box().execute("update_setting", ["name": "theme", "value": "light"], screen: .zero)
        XCTAssertEqual(s.text, "set theme=light")
    }

    func testStatusToolReportsTheMac() async {
        let r = await box().execute("mac_status", ["focus": "storage"], screen: .zero)
        XCTAssertTrue(r.text.contains("Storage:"), r.text)
    }
}

final class MemoryTests: XCTestCase {
    func store() -> MemoryStore {
        MemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-mem-\(UUID().uuidString)"))
    }

    func testConversationSurvivesARestart() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-mem-\(UUID().uuidString)")
        let a = MemoryStore(directory: dir)
        a.append(Turn(role: "user", text: "weather in Dhaka?", mode: "web"))
        a.append(Turn(role: "assistant", text: "31 degrees and humid.", mode: "web"))
        let b = MemoryStore(directory: dir)
        XCTAssertEqual(b.context().map(\.text), ["weather in Dhaka?", "31 degrees and humid."])
        XCTAssertEqual(b.context().last?.mode, "web")
    }

    func testLongPauseKeepsOnlyTheLastExchange() {
        let m = store()
        let old = Date().addingTimeInterval(-3 * 86_400)
        m.append(Turn(role: "user", text: "first", at: old))
        m.append(Turn(role: "assistant", text: "one", at: old))
        m.append(Turn(role: "user", text: "second", at: old.addingTimeInterval(60)))
        m.append(Turn(role: "assistant", text: "two", at: old.addingTimeInterval(61)))
        XCTAssertEqual(m.context().map(\.text), ["second", "two"])
        m.append(Turn(role: "user", text: "today"))
        m.append(Turn(role: "assistant", text: "now"))
        XCTAssertEqual(m.context().map(\.text), ["today", "now"])
    }

    func testProfileCombinesNameAboutAndFacts() {
        let m = store()
        m.setAbout("Does: CS student. Based in Dhaka.")
        m.addFact("User's sister is Mim.")
        m.addFact("user's sister is mim.")
        XCTAssertEqual(m.facts.count, 1)
        let p = m.profile(name: "Ador")
        for part in ["Ador", "CS student", "Mim"] { XCTAssertTrue(p.contains(part), part) }
    }

    func testFollowUpsAreRecognised() {
        for t in ["and tomorrow?", "what about Chittagong", "send it to her", "do the same for Desktop", "tell me more", "why?"] {
            XCTAssertTrue(Router.isFollowUp(t), t)
        }
        for t in ["what's the capital of Japan", "open Safari", "how's my battery doing today with all these apps open right now"] {
            XCTAssertFalse(Router.isFollowUp(t), t)
        }
    }

    func testLearnerKeepsOnlyNewSafeFacts() {
        XCTAssertTrue(Learner.worthChecking("I study computer science at AIUB"))
        XCTAssertFalse(Learner.worthChecking("what's the weather"))
        let found = Learner.parse("- User studies at AIUB.\n- User's password is hunter2\nUser's sister is Mim\nNONE", known: ["User's sister is Mim."])
        XCTAssertEqual(found, ["User studies at AIUB."])
        XCTAssertTrue(Learner.parse("NONE", known: []).isEmpty)
    }

    func testAboutAnswersBecomeAParagraph() {
        var s = JarvisSettings()
        s.aboutWork = "CS student at AIUB"
        s.aboutPlace = "Dhaka"
        s.aboutFocus = ["Studies", "Coding"]
        XCTAssertEqual(s.aboutText, "Does: CS student at AIUB. Based in Dhaka. Interests: Studies, Coding.")
    }

    func testOldSettingsHideTelemetryOnce() throws {
        let old = try JSONSerialization.data(withJSONObject: ["showTelemetry": true, "accentHex": "#8B7CFF"])
        let s = JarvisSettings.load(from: old)
        XCTAssertFalse(s.showTelemetry)
        XCTAssertEqual(s.accentHex, "#8B7CFF")
        var again = s
        again.showTelemetry = true
        let reloaded = JarvisSettings.load(from: try JSONEncoder().encode(again))
        XCTAssertTrue(reloaded.showTelemetry)
    }
}

final class InterviewTests: XCTestCase {
    func testNamesFromNaturalAnswers() {
        XCTAssertEqual(Interview.name(from: "You can call me Ador."), "Ador")
        XCTAssertEqual(Interview.name(from: "my name is alvi ador"), "Alvi")
        XCTAssertEqual(Interview.name(from: "I'm Alvi Ador"), "Alvi Ador")
        XCTAssertEqual(Interview.name(from: "Ador"), "Ador")
        XCTAssertEqual(Interview.name(from: "just Mim please"), "Mim")
    }

    func testOtherAnswers() {
        XCTAssertEqual(Interview.work(from: "I'm a computer science student at AIUB."), "computer science student at AIUB")
        XCTAssertEqual(Interview.place(from: "I live in Dhaka, Bangladesh"), "Dhaka, Bangladesh")
        XCTAssertEqual(Interview.focus(from: "mostly my studies and coding, and keeping the Mac clean"),
                       ["Studies", "Coding", "Keeping my Mac healthy"])
        XCTAssertEqual(Interview.style(from: "short and to the point please"), "brief")
        XCTAssertEqual(Interview.style(from: "I like a bit more detail"), "detailed")
        XCTAssertEqual(Interview.style(from: "depends"), "balanced")
        XCTAssertEqual(Interview.notes(from: "No, that's it."), "")
        XCTAssertEqual(Interview.notes(from: "I play football on Fridays"), "I play football on Fridays")
    }

    func testQuestionsUseTheName() {
        XCTAssertTrue(Interview.questions(name: "Ador")[1].text.contains("Ador"))
        XCTAssertFalse(Interview.questions(name: "")[1].text.contains(", ."))
    }

    func testRefinedProfileIsParsedSafely() {
        let reply = """
        ```json
        {"name": "Ador", "work": "Computer science student at AIUB", "place": "Dhaka, Bangladesh",
         "focus": ["Studies", "Coding", "Juggling"], "style": "brief", "notes": "Plays football on Fridays.",
         "facts": ["User plays football on Fridays.", "User's password is 1234"]}
        ```
        """
        let p = Interview.parseProfile(reply)!
        XCTAssertEqual(p.name, "Ador")
        XCTAssertEqual(p.focus, ["Studies", "Coding"])
        XCTAssertEqual(p.style, "brief")
        XCTAssertEqual(p.facts, ["User plays football on Fridays."])
        XCTAssertNil(Interview.parseProfile("Sorry, I can't help with that."))
    }
}

final class QuotaTests: XCTestCase {
    func testRefusalsAreUnderstood() {
        let perDay = #"{"error":{"code":429,"message":"You exceeded your current quota. Quota exceeded for metric: generativelanguage.googleapis.com/generate_content_free_tier_requests, limit: 20, model: gemini-3.8-flash","status":"RESOURCE_EXHAUSTED","details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{"quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"41s"}]}}"#
        XCTAssertEqual(QuotaBook.parse(perDay).kind, .perDay)
        let perMinute = #"{"error":{"code":429,"message":"Quota exceeded","details":[{"violations":[{"quotaId":"GenerateRequestsPerMinutePerProjectPerModel-FreeTier"}]},{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"7s"}]}}"#
        let m = QuotaBook.parse(perMinute)
        XCTAssertEqual(m.kind, .perMinute)
        XCTAssertEqual(m.retryAfter, 7)
        let none = #"{"error":{"code":429,"message":"Quota exceeded for metric: generate_content_free_tier_requests, limit: 0, model: gemini-3.1-pro"}}"#
        XCTAssertEqual(QuotaBook.parse(none).kind, .noFreeTier)
    }

    func testRestingModelsAreSkippedUntilTheyReset() {
        let book = QuotaBook()
        let model = "gemini-test-\(UUID().uuidString)"
        let now = Date()
        book.note(model, body: #"{"error":{"details":[{"violations":[{"quotaId":"PerMinute"}]},{"retryDelay":"5s"}]}}"#, now: now)
        XCTAssertFalse(book.usable(model, now: now.addingTimeInterval(2)))
        XCTAssertTrue(book.usable(model, now: now.addingTimeInterval(30)))
        XCTAssertGreaterThan(QuotaBook.nextPacificMidnight(after: now), now)
    }

    func testEachTierHasStandIns() {
        let models = ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3-flash-preview", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite", "gemini-3.1-pro-preview"]
        XCTAssertEqual(ModelPicker.ranked(.flash, in: models), ["gemini-3.8-flash", "gemini-3.6-flash", "gemini-3-flash-preview"])
        var s = JarvisSettings()
        s.knownModels = models
        // Search starts on the Lite models (biggest free allowance) and steps up to Flash when they run out.
        let chain = Router().chain(for: .web, settings: s)
        XCTAssertEqual(chain.first, s.liteModel)
        XCTAssertTrue(chain.contains("gemini-3.1-flash-lite"))
        XCTAssertTrue(chain.contains("gemini-3.8-flash"))
        XCTAssertTrue(chain.contains("gemini-3.6-flash"))
        XCTAssertLessThan(chain.firstIndex(of: "gemini-3.1-flash-lite")!, chain.firstIndex(of: "gemini-3.8-flash")!)
        XCTAssertEqual(Set(chain).count, chain.count)
        // Screen work stays on Flash first.
        XCTAssertEqual(Router().chain(for: .screen, settings: s).first, s.flashModel)
    }
}

final class AttachmentTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testCodeAndTextBecomeText() throws {
        let u = dir.appendingPathComponent("main.swift")
        try "print(\"hi\")".write(to: u, atomically: true, encoding: .utf8)
        let a = try Attachment.load(u)
        XCTAssertEqual(a.kind, .text)
        XCTAssertTrue((a.geminiPart["text"] as? String)?.contains("print") == true)
        XCTAssertEqual(a.claudeBlock["type"] as? String, "text")
    }

    func testImagesBecomeJPEGWithAThumbnail() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let u = dir.appendingPathComponent("photo.png")
        try rep.representation(using: .png, properties: [:])!.write(to: u)
        let a = try Attachment.load(u)
        XCTAssertEqual(a.kind, .image)
        XCTAssertEqual(a.mime, "image/jpeg")
        XCTAssertNotNil(a.thumbnail)
        let src = CGImageSourceCreateWithData(a.data as CFData, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 2048)
        XCTAssertEqual(((a.claudeBlock["source"] as? [String: Any])?["media_type"]) as? String, "image/jpeg")
    }

    func testPDFsAndAudioGoInline() throws {
        let pdf = dir.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 test".utf8).write(to: pdf)
        let a = try Attachment.load(pdf)
        XCTAssertEqual(a.kind, .pdf)
        XCTAssertEqual(((a.geminiPart["inline_data"] as? [String: Any])?["mime_type"]) as? String, "application/pdf")
        XCTAssertEqual(a.claudeBlock["type"] as? String, "document")
        let mp3 = dir.appendingPathComponent("memo.mp3")
        try Data(repeating: 1, count: 100).write(to: mp3)
        XCTAssertTrue(try Attachment.load(mp3).needsGemini)
    }

    func testUnsupportedAndOversizedAreRefused() throws {
        let bin = dir.appendingPathComponent("tool.dylib")
        try Data(repeating: 0, count: 10).write(to: bin)
        XCTAssertThrowsError(try Attachment.load(bin))
        let big = dir.appendingPathComponent("huge.pdf")
        try Data(repeating: 0, count: Attachment.maxInline + 1).write(to: big)
        XCTAssertThrowsError(try Attachment.load(big))
    }
}

final class ConversationFlowTests: XCTestCase {
    func testUnfinishedSentencesGetMoreTime() {
        for t in ["remind me to call mum and", "open the file with", "I want to know about,", "set a timer because um"] {
            XCTAssertTrue(VoiceEngine.soundsUnfinished(t), t)
        }
        for t in ["what's the weather in Dhaka", "open Safari", "thanks"] {
            XCTAssertFalse(VoiceEngine.soundsUnfinished(t), t)
        }
    }

    func testHesitationGetsMoreTime() {
        for t in ["can you open the um", "I I want to book a", "send it to the the", "what is the, how do you say", "remind me about uh"] {
            XCTAssertTrue(VoiceEngine.soundsHesitant(t), t)
        }
        for t in ["what's the weather in Dhaka", "open Safari and play music", "do you know the time"] {
            XCTAssertFalse(VoiceEngine.soundsHesitant(t), t)
        }
    }

    func testOlderSettingsMoveToTheAdaptivePause() throws {
        let old = try JSONSerialization.data(withJSONObject: ["settingsVersion": 2, "responsePause": 0.9, "showTelemetry": true])
        let s = JarvisSettings.load(from: old)
        XCTAssertEqual(s.responsePause, 1.1)   // unfinished and hesitant sentences get extra time on top
        XCTAssertTrue(s.patientListening)
        XCTAssertTrue(s.showTelemetry)   // version 2 already chose this, so it stays
        XCTAssertTrue(s.bargeIn)
    }
}

final class AlertKindTests: XCTestCase {
    func testEachWarningSaysWhatItIsAbout() {
        let s = MacCareTests().snapshot(battery: 8, free: 3_000_000_000, pressure: "critical", thermal: "serious")
        XCTAssertEqual(SystemMonitor.alertItems(s).map(\.kind), [.battery, .storage, .memory, .thermal])
        XCTAssertEqual(SystemMonitor.alerts(s).count, 4)
    }
}

final class VoiceUpgradeTests: XCTestCase {
    func testWakeWordNearMisses() {
        for w in ["Jarvis", "jarvis,", "Jervis", "Javis", "Jarvas", "Garvis"] { XCTAssertTrue(VoiceEngine.isWake(w), w) }
        for w in ["service", "jar", "travel", "harvest", "nervous"] { XCTAssertFalse(VoiceEngine.isWake(w), w) }
    }

    func testProfileLearnsAndKeepsUp() {
        var rng = SystemRandomNumberGenerator()
        let me = (0..<57).map { _ in Float.random(in: -1...1, using: &rng) }
        func noisy(_ v: [Float], _ n: Float = 0.12) -> [Float] { v.map { $0 + Float.random(in: -n...n) } }
        var p = VoiceProfile.enroll((0..<4).map { _ in noisy(me) })!
        XCTAssertEqual(p.samples.count, 4)
        for _ in 0..<50 { p.learn(noisy(me)) }
        XCTAssertEqual(p.samples.count, VoiceProfile.maxSamples)
        XCTAssertTrue(p.matches(noisy(me), strictness: 0.5))
        XCTAssertFalse(p.matches((0..<57).map { _ in Float.random(in: -1...1, using: &rng) }, strictness: 0.5))
    }

    func testOldVoiceprintsStillLoad() throws {
        let old = try JSONSerialization.data(withJSONObject: ["center": [0.1, 0.2], "floor": 0.8])
        let p = try JSONDecoder().decode(VoiceProfile.self, from: old)
        XCTAssertTrue(p.samples.isEmpty)
        XCTAssertEqual(p.score([0.1, 0.2]), 1, accuracy: 0.001)
    }

    func testOnlyExtremeLongStrainIsReported() {
        let calm = MacCareTests().snapshot(battery: 12)
        XCTAssertTrue(SystemMonitor.extremeItems(calm).isEmpty)   // 12% battery is not an emergency
        let bad = MacCareTests().snapshot(battery: 4, free: 1_000_000_000, pressure: "critical", thermal: "serious")
        XCTAssertEqual(Set(SystemMonitor.extremeItems(bad).map(\.kind)), [.battery, .storage, .memory, .thermal])
        XCTAssertGreaterThanOrEqual(SystemMonitor.patience(.memory), 15 * 60)
        XCTAssertEqual(SystemMonitor.patience(.battery), 0)
    }

    func testOlderSettingsGetAGentlerMicLevel() throws {
        let old = try JSONSerialization.data(withJSONObject: ["settingsVersion": 3, "micThreshold": 0.02])
        let s = JarvisSettings.load(from: old)
        XCTAssertEqual(s.micThreshold, 0.006)
        XCTAssertTrue(s.answerWhenCalled)
    }
}

final class LanguageAndEffortTests: XCTestCase {
    func testLanguagesAreDetected() {
        XCTAssertEqual(Language.detect("What's the weather like in Dhaka today?"), "en")
        XCTAssertEqual(Language.detect("আজকে ঢাকার আবহাওয়া কেমন?"), "bn")
        XCTAssertEqual(Language.detect("आज मौसम कैसा है?"), "hi")
        XCTAssertNil(Language.detect("ok"))
        XCTAssertFalse(Language.isEnglish("¿Qué hora es en Madrid ahora mismo?"))
    }

    func testHeardLineIsSplitFromTheAnswer() {
        let r = Language.splitHeard("Heard: আজকের তারিখ কত?\nআজ ১৬ অক্টোবর।")
        XCTAssertEqual(r.heard, "আজকের তারিখ কত?")
        XCTAssertEqual(r.rest, "আজ ১৬ অক্টোবর।")
        XCTAssertNil(Language.splitHeard("Just an answer.").heard)
    }

    func testSpeechBecomesACompactWAV() throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48_000)!
        buf.frameLength = 48_000
        for i in 0..<48_000 { buf.floatChannelData![0][i] = sin(Float(i) * 0.05) * 0.3 }
        let wav = try XCTUnwrap(VoiceEngine.wav(from: [buf]))
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(wav.count, 44 + 16_000 * 2, accuracy: 400)   // one second at 16 kHz, 16-bit mono
    }

    func testEffortShapesThinkingAndScope() {
        var s = JarvisSettings()
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.8-flash", mode: .chat, effort: "low"), .level("low"))
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.8-flash", mode: .chat, effort: "max"), .level("high"))
        XCTAssertEqual(GeminiAgent.thinking(for: "gemini-3.8-flash", mode: .chat), .level("low"))
        s.effort = "max"
        XCTAssertEqual(s.toolSteps, 24)
        XCTAssertEqual(s.tokenScale, 4)
        s.usageSaver = true
        XCTAssertEqual(s.effectiveEffort, "low")
        XCTAssertEqual(s.toolSteps, 6)
        s.knownModels = ["gemini-3.8-flash", "gemini-3.5-flash-lite", "gemini-3.1-flash-lite"]
        XCTAssertFalse(Router().chain(for: .chat, settings: s).contains("gemini-3.8-flash"))   // the saver never steps up
        XCTAssertEqual(Router().tier(for: .hard, settings: s), .flash)
    }

    func testRealQuestionsAreRecognised() {
        XCTAssertTrue(Router.isSubstantive("why is the sky blue"))
        XCTAssertTrue(Router.isSubstantive("help me plan a three day trip to Cox's Bazar"))
        XCTAssertFalse(Router.isSubstantive("hi there"))
    }
}

final class MacControlTests: XCTestCase {
    func testRiskyScriptsAreSpotted() {
        XCTAssertTrue(Scripting.isRisky("tell application \"Finder\" to delete file \"a\""))
        XCTAssertTrue(Scripting.isRisky("do shell script \"ls\""))
        XCTAssertTrue(Scripting.isRisky("tell application \"System Events\" to keystroke \"hi\""))
        XCTAssertFalse(Scripting.isRisky("tell application \"Music\" to play"))
    }

    func testFileOperationsStayInTheHomeFolder() async throws {
        XCTAssertFalse(FileOps.allowed("/etc/hosts"))
        XCTAssertFalse(FileOps.allowed("~/Library/Preferences/x.plist"))
        XCTAssertFalse(FileOps.allowed("~/.ssh/config"))
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/JarvisTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "hi".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let made = await FileOps.perform("make_folder", from: "", to: dir.path, name: "Box")
        XCTAssertTrue(made.hasPrefix("Made"), made)
        let moved = await FileOps.perform("move", from: dir.appendingPathComponent("a.txt").path, to: dir.appendingPathComponent("Box").path, name: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Box/a.txt").path), moved)
        let copied = await FileOps.perform("copy", from: dir.appendingPathComponent("Box/a.txt").path, to: dir.appendingPathComponent("Box").path, name: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Box/a 2.txt").path), copied)   // never overwrites
        let zipped = await FileOps.perform("zip", from: dir.appendingPathComponent("Box").path, to: "", name: "")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("Box.zip").path), zipped)
    }

    func testProjectsAreRecognised() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-proj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "{}".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(Dev.command("test", in: dir), ["npm", "test", "--silent"])
        XCTAssertEqual(Dev.command("lint", in: dir)?.last, ".")
        XCTAssertNil(Dev.repo("/tmp"))
        // A project inside the home folder, found from one of its subfolders.
        let home = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents/JarvisRepoTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Sources/App"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        XCTAssertEqual(Dev.repo(home.appendingPathComponent("Sources/App").path)?.lastPathComponent, home.lastPathComponent)
    }

    func testDatabaseChangesAreSpotted() {
        XCTAssertTrue(SQLite.isWrite("  DELETE FROM users"))
        XCTAssertTrue(SQLite.isWrite("insert into t values (1)"))
        XCTAssertFalse(SQLite.isWrite("select * from users"))
    }

    func testMarkdownBecomesADocument() throws {
        let html = Documents.html("# Proposal\n\nFor **Acme**, with *care*.\n\n- Design\n- Build\n\n1. Week one\n2. Week two")
        for part in ["<h1>Proposal</h1>", "<b>Acme</b>", "<i>care</i>", "<ul>", "<li>Design</li>", "<ol>"] { XCTAssertTrue(html.contains(part), part) }
        let saved = Documents.save(name: "Jarvis test \(UUID().uuidString.prefix(6))", format: "docx", content: "# Hello\n\nWorld")
        XCTAssertTrue(saved.hasPrefix("Saved "), saved)
        let path = (String(saved.dropFirst(6)) as NSString).expandingTildeInPath
        XCTAssertGreaterThan((try? Data(contentsOf: URL(fileURLWithPath: path)).count) ?? 0, 1000)
        try? FileManager.default.removeItem(atPath: path)
    }

    func testFeedsAreParsed() {
        let rss = """
        <rss><channel><item><title>React developer (remote)</title><link>https://example.com/1</link>
        <pubDate>Fri, 16 Oct 2026</pubDate><description><![CDATA[<p>Build a dashboard</p>]]></description></item></channel></rss>
        """
        let p = Feeds.Parser()
        let x = XMLParser(data: Data(rss.utf8))
        x.delegate = p
        x.parse()
        XCTAssertEqual(p.items.first?["title"], "React developer (remote)")
        XCTAssertEqual(p.items.first?["link"], "https://example.com/1")
    }

    func testOnlyRelevantToolsAreSent() {
        func names(_ hint: String) -> Set<String> {
            Set(ToolBox(settings: JarvisSettings(), memory: MemoryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-test-memory")),
                        confirm: { _ in true }, notify: { _, _ in }, hint: hint).declarations(screen: false).compactMap { $0["name"] as? String })
        }
        XCTAssertTrue(names("commit my changes in the jarvis repo").contains("dev"))
        XCTAssertFalse(names("what's the capital of Japan").contains("dev"))
        XCTAssertTrue(names("play some lofi on spotify").contains("spotify"))
        XCTAssertTrue(names("").contains("read_feed"))   // automations get everything
        XCTAssertTrue(names("what's the capital of Japan").contains("ui"))   // core tools are always there
    }

    func testComputerUseKeysMapToMacKeys() {
        XCTAssertEqual(ComputerUseAgent.keyName("Control"), "ctrl")
        XCTAssertEqual(ComputerUseAgent.keyName("Meta"), "cmd")
        XCTAssertEqual(ComputerUseAgent.keyName("Enter"), "return")
        var s = JarvisSettings()
        s.knownModels = ["gemini-3.8-flash", "gemini-4-argon"]
        XCTAssertEqual(ComputerUseAgent.pick(s), s.flashModel)
        s.effort = "max"
        XCTAssertEqual(ComputerUseAgent.pick(s), "gemini-4-argon")
    }
}


final class AIAppTests: XCTestCase {
    func testRequestsForOtherAssistantsAreRecognised() {
        let r = AIApps.request(in: "Ask ChatGPT to make me a workout plan for gaining muscle")
        XCTAssertEqual(r?.target.id, "chatgpt")
        XCTAssertEqual(r?.ask, "make me a workout plan for gaining muscle")
        XCTAssertEqual(AIApps.request(in: "tell claude about my essay on climate policy")?.target.id, "claude")
        XCTAssertEqual(AIApps.request(in: "use grok to explain black holes simply")?.ask, "explain black holes simply")
        XCTAssertEqual(AIApps.request(in: "open Gemini and ask it to summarise the news")?.target.id, "gemini")
        XCTAssertEqual(AIApps.request(in: "type this into perplexity: best laptops under 1000 dollars")?.ask, "best laptops under 1000 dollars")
        XCTAssertNil(AIApps.request(in: "what's the weather today"))
        XCTAssertNil(AIApps.request(in: "ask chatgpt"))
    }

    func testAssistantsHaveSensiblePlaces() {
        for t in AIApps.targets { XCTAssertTrue(t.web.hasPrefix("https://"), t.id) }
        XCTAssertEqual(AIApps.target("Chat GPT")?.name, "ChatGPT")
        XCTAssertEqual(AIApps.target("grock")?.id, "grok")
    }
}

final class HearingTests: XCTestCase {
    func testMishearingsAreFixedInContext() {
        let fixed = [
            "Create a gift commit and push it to Jeb": "Create a git commit and push it to GitHub",
            "Create a good commit and push it to the top": "Create a git commit and push it to GitHub",
            "Create a get commit and push it to get hard": "Create a git commit and push it to GitHub",
            "push my changes to get hub": "push my changes to GitHub",
            "ask chatting to write a cover letter": "ask ChatGPT to write a cover letter",
            "tell chat GPT to plan my week": "tell ChatGPT to plan my week",
            "How much feet is space? Does my Mac have?": "How much free disk space? Does my Mac have?",
        ]
        for (heard, meant) in fixed { XCTAssertEqual(Hearing.correct(heard), meant, heard) }
        // Everyday English is left alone.
        for t in ["I want to get a gift for my mum", "get status of my order", "push it to the top of the list",
                  "Peter Parker is my favourite hero", "what's the weather in Dhaka tomorrow"] {
            XCTAssertEqual(Hearing.correct(t), t)
        }
    }

    func testCorrectionsAreLearnedWithTheirContext() {
        let fixes = Hearing.corrections(heard: "Hey Jarvis, what's the weather in Parker tomorrow?", meant: "what's the weather in Dhaka tomorrow")
        XCTAssertEqual(fixes, ["in parker tomorrow": "in Dhaka tomorrow"])
        XCTAssertEqual(Hearing.correct("weather in Parker tomorrow?", learned: fixes), "weather in Dhaka tomorrow?")
        XCTAssertEqual(Hearing.correct("Peter Parker tomorrow", learned: fixes), "Peter Parker tomorrow")
        let git = Hearing.corrections(heard: "Create a gift commit and push it to get up", meant: "Create a git commit and push it to GitHub")
        XCTAssertEqual(git["a gift commit"], "a git commit")
        XCTAssertEqual(git["to get up"], "to GitHub")
        XCTAssertEqual(Hearing.newWords(heard: "push it to get up", meant: "push it to GitHub"), ["GitHub"])
    }

    func testChangesOfMindAreNotLearned() {
        XCTAssertTrue(Hearing.corrections(heard: "what's the weather in London", meant: "what's the weather in Paris").isEmpty)
        XCTAssertTrue(Hearing.corrections(heard: "set a timer for ten minutes", meant: "what's on my calendar today").isEmpty)
        XCTAssertTrue(Hearing.soundsAlike("Parker", "Dhaka"))
        XCTAssertTrue(Hearing.soundsAlike("get up", "GitHub"))
        XCTAssertFalse(Hearing.soundsAlike("London", "Paris"))
    }

    func testProfileWordsAndHintsStayFocused() {
        var s = JarvisSettings()
        s.userName = "Alvi Ador"
        s.aboutWork = "Student at AIUB studying CSE"
        s.aboutPlace = "Dhaka, Bangladesh"
        XCTAssertEqual(Hearing.places(s), ["Dhaka", "Bangladesh"])
        XCTAssertTrue(Hearing.profileWords(s).contains("AIUB"))
        XCTAssertFalse(Hearing.profileWords(s).contains("Student"))
        let hints = Hearing.contextualStrings(wakeWord: "jarvis", settings: s, apps: (1...200).map { "App \($0)" })
        XCTAssertLessThanOrEqual(hints.count, 100)
        XCTAssertTrue(hints.contains("Alvi") && hints.contains("Dhaka") && hints.contains("ChatGPT"))
        XCTAssertEqual(hints.filter { $0 == "Jarvis" }.count, 1)
    }
}
