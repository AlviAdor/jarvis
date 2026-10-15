import XCTest
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
        XCTAssertEqual(s.aboutText, "Does: CS student at AIUB. Based in Dhaka. Mostly wants help with: Studies, Coding.")
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
