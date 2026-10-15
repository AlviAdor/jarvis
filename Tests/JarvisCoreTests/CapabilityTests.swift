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
        ToolBox(settings: s, memory: MemoryStore(), confirm: confirm, notify: { _, _ in },
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
