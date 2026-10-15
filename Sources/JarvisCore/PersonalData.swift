import Foundation
import AppKit
import EventKit
import Contacts
import PDFKit

/// Calendar and Reminders through EventKit. macOS asks once for each.
public enum Agenda {
    static let store = EKEventStore()

    static func access(_ type: EKEntityType) async -> Bool {
        let status = EKEventStore.authorizationStatus(for: type)
        if status == .fullAccess { return true }
        if status == .denied || status == .restricted { return false }
        do {
            return type == .event ? try await store.requestFullAccessToEvents() : try await store.requestFullAccessToReminders()
        } catch {
            return false
        }
    }

    public static func status(_ type: EKEntityType) -> Bool? {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: return true
        case .notDetermined: return nil
        default: return false
        }
    }

    static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM HH:mm"
        return f
    }()

    /// Accepts "2026-10-16 14:30", "2026-10-16T14:30", "14:30" (today) or "2026-10-16".
    public static func parse(_ s: String, relativeTo now: Date = Date()) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        let parts = t.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) {
            return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
        }
        return nil
    }

    public static func events(days: Int, from: Date = Calendar.current.startOfDay(for: Date())) async -> String {
        guard await access(.event) else { return "Calendar access is off. Allow it in System Settings, Privacy and Security, Calendars." }
        let end = Calendar.current.date(byAdding: .day, value: max(1, days), to: from) ?? from
        let pred = store.predicateForEvents(withStart: from, end: end, calendars: nil)
        let list = store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(40)
        guard !list.isEmpty else { return "No events." }
        return list.map { e in
            var line = e.isAllDay ? "\(Agenda.dayFormat.string(from: e.startDate).prefix(10)) all day" : Agenda.dayFormat.string(from: e.startDate)
            line += ": \(e.title ?? "Untitled")"
            if let loc = e.location, !loc.isEmpty { line += " @ \(loc)" }
            line += " [id \(e.eventIdentifier ?? "")]"
            return line
        }.joined(separator: "\n")
    }

    public static func createEvent(title: String, start: Date, end: Date?, location: String, notes: String) async -> String {
        guard await access(.event) else { return "Calendar access is off." }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end ?? start.addingTimeInterval(3600)
        if !location.isEmpty { e.location = location }
        if !notes.isEmpty { e.notes = notes }
        e.calendar = store.defaultCalendarForNewEvents
        do {
            try store.save(e, span: .thisEvent)
            return "Added \u{201C}\(title)\u{201D} on \(dayFormat.string(from: e.startDate))."
        } catch {
            return "Couldn't add the event: \(error.localizedDescription)"
        }
    }

    public static func deleteEvent(id: String) async -> String {
        guard await access(.event) else { return "Calendar access is off." }
        guard let e = store.event(withIdentifier: id) else { return "Couldn't find that event." }
        do {
            try store.remove(e, span: .thisEvent)
            return "Deleted \u{201C}\(e.title ?? "the event")\u{201D}."
        } catch {
            return "Couldn't delete it: \(error.localizedDescription)"
        }
    }

    public static func reminders(includeDone: Bool = false) async -> String {
        guard await access(.reminder) else { return "Reminders access is off. Allow it in System Settings, Privacy and Security, Reminders." }
        let pred = includeDone ? store.predicateForReminders(in: nil)
            : store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let items: [EKReminder] = await withCheckedContinuation { c in
            store.fetchReminders(matching: pred) { c.resume(returning: $0 ?? []) }
        }
        guard !items.isEmpty else { return "No open reminders." }
        return items.prefix(40).map { r in
            var line = "\(r.isCompleted ? "[done] " : "")\(r.title ?? "Untitled")"
            if let d = r.dueDateComponents?.date { line += " (due \(dayFormat.string(from: d)))" }
            line += " [list \(r.calendar.title), id \(r.calendarItemIdentifier)]"
            return line
        }.joined(separator: "\n")
    }

    public static func addReminder(title: String, due: Date?, list: String, notes: String) async -> String {
        guard await access(.reminder) else { return "Reminders access is off." }
        let r = EKReminder(eventStore: store)
        r.title = title
        if !notes.isEmpty { r.notes = notes }
        r.calendar = store.calendars(for: .reminder).first { $0.title.caseInsensitiveCompare(list) == .orderedSame }
            ?? store.defaultCalendarForNewReminders()
        if let due {
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(r, commit: true)
            return "Reminder added" + (due.map { " for \(dayFormat.string(from: $0))" } ?? "") + "."
        } catch {
            return "Couldn't add the reminder: \(error.localizedDescription)"
        }
    }

    public static func completeReminder(id: String) async -> String {
        guard await access(.reminder) else { return "Reminders access is off." }
        guard let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return "Couldn't find that reminder." }
        r.isCompleted = true
        do {
            try store.save(r, commit: true)
            return "Marked \u{201C}\(r.title ?? "it")\u{201D} as done."
        } catch {
            return "Couldn't update it: \(error.localizedDescription)"
        }
    }
}

public enum People {
    public static func status() -> Bool? {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .notDetermined: return nil
        default: return false
        }
    }

    public static func search(_ query: String) async -> String {
        let store = CNContactStore()
        let ok = (try? await store.requestAccess(for: .contacts)) ?? false
        guard ok else { return "Contacts access is off. Allow it in System Settings, Privacy and Security, Contacts." }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactBirthdayKey] as [CNKeyDescriptor]
        let pred = CNContact.predicateForContacts(matchingName: query)
        guard let found = try? store.unifiedContacts(matching: pred, keysToFetch: keys), !found.isEmpty else { return "No contact matches \u{201C}\(query)\u{201D}." }
        return found.prefix(8).map { c in
            var parts = ["\(c.givenName) \(c.familyName)".trimmingCharacters(in: .whitespaces)]
            if !c.organizationName.isEmpty { parts.append(c.organizationName) }
            parts += c.phoneNumbers.prefix(3).map { "phone \($0.value.stringValue)" }
            parts += c.emailAddresses.prefix(3).map { "email \($0.value as String)" }
            if let b = c.birthday, let m = b.month, let d = b.day { parts.append("birthday \(d)/\(m)") }
            return parts.joined(separator: ", ")
        }.joined(separator: "\n")
    }
}

/// Apple apps driven through AppleScript. macOS asks once per app the first time.
public enum AppleApps {
    static func q(_ s: String) -> String { "\"" + AppleScript.escape(s) + "\"" }

    public static func createNote(title: String, body: String) async -> String {
        let html = "<h1>\(escapeHTML(title))</h1>" + body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "<div>\(escapeHTML(String($0)))</div>" }.joined()
        return await AppleScript.run("tell application \"Notes\" to make new note at default account with properties {name:\(q(title)), body:\(q(html))}\nreturn \"Note created.\"")
    }

    public static func searchNotes(_ query: String) async -> String {
        await AppleScript.run("""
        tell application "Notes"
            set out to ""
            set found to (notes whose name contains \(q(query)) or plaintext contains \(q(query)))
            set n to count of found
            if n > 8 then set n to 8
            repeat with i from 1 to n
                set t to plaintext of item i of found
                if (length of t) > 400 then set t to text 1 thru 400 of t
                set out to out & "# " & (name of item i of found) & linefeed & t & linefeed & "---" & linefeed
            end repeat
            if out is "" then return "No notes match."
            return out
        end tell
        """)
    }

    public static func sendMessage(to: String, text: String) async -> String {
        await AppleScript.run("""
        tell application "Messages"
            set svc to 1st account whose service type = iMessage
            send \(q(text)) to participant \(q(to)) of svc
        end tell
        return "Sent."
        """)
    }

    public static func nowPlaying() async -> String {
        await AppleScript.run("""
        set out to "Nothing is playing."
        if application "Music" is running then
            tell application "Music"
                if player state is playing then set out to "Music: " & (name of current track) & " by " & (artist of current track)
            end tell
        end if
        if application "Spotify" is running then
            tell application "Spotify"
                if player state is playing then set out to "Spotify: " & (name of current track) & " by " & (artist of current track)
            end tell
        end if
        return out
        """)
    }

    public static func playMusic(_ query: String) async -> String {
        if query.isEmpty { return await AppleScript.run("tell application \"Music\" to play\nreturn \"Playing.\"") }
        return await AppleScript.run("""
        tell application "Music"
            set hits to (search playlist "Library" for \(q(query)))
            if hits is {} then return "Nothing in your Music library matches that."
            play item 1 of hits
            return "Playing " & (name of item 1 of hits) & " by " & (artist of item 1 of hits) & "."
        end tell
        """)
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

/// Volume, brightness, media keys, appearance and power, the way the keyboard's own keys do it.
public enum MacControl {
    // NX_KEYTYPE values from IOKit's ev_keymap.h
    static let keys: [String: Int32] = [
        "volume_up": 0, "volume_down": 1, "brightness_up": 2, "brightness_down": 3, "mute": 7,
        "play_pause": 16, "next": 17, "previous": 18,
    ]

    /// Posts a hardware media key, so it works with whatever app is playing.
    static func mediaKey(_ code: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = Int((code << 16) | (down ? 0xA00 : 0xB00))
            let e = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                                       windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1)
            e?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    public static let actions = ["play_pause", "next", "previous", "volume_up", "volume_down", "mute", "set_volume",
                                 "brightness_up", "brightness_down", "now_playing", "play_music", "dark_mode_on",
                                 "dark_mode_off", "toggle_dark_mode", "sleep_display", "lock_screen", "wifi_on", "wifi_off",
                                 "show_desktop"]

    public static func perform(_ action: String, value: String) async -> String {
        if let code = keys[action] {
            let times = action.hasPrefix("brightness") || action.hasPrefix("volume") ? max(1, min(Int(value) ?? 2, 16)) : 1
            for _ in 0..<times {
                await MainActor.run { mediaKey(code) }
                try? await Task.sleep(nanoseconds: 40_000_000)
            }
            return "Done."
        }
        switch action {
        case "set_volume":
            let v = max(0, min(Int(value) ?? 50, 100))
            return await AppleScript.run("set volume output volume \(v)\nreturn \"Volume set to \(v)%.\"")
        case "now_playing":
            return await AppleApps.nowPlaying()
        case "play_music":
            return await AppleApps.playMusic(value)
        case "dark_mode_on", "dark_mode_off", "toggle_dark_mode":
            let to = action == "toggle_dark_mode" ? "not dark mode" : (action == "dark_mode_on" ? "true" : "false")
            return await AppleScript.run("tell application \"System Events\" to tell appearance preferences to set dark mode to \(to)\nreturn \"Appearance changed.\"")
        case "sleep_display":
            _ = await Run.capture("/usr/bin/pmset", ["displaysleepnow"])
            return "Display is asleep."
        case "lock_screen":
            _ = await Run.capture("/usr/bin/osascript", ["-e", "tell application \"System Events\" to keystroke \"q\" using {control down, command down}"])
            return "Locked."
        case "wifi_on", "wifi_off":
            let dev = await wifiDevice()
            _ = await Run.capture("/usr/sbin/networksetup", ["-setairportpower", dev, action == "wifi_on" ? "on" : "off"])
            return "Wi-Fi turned \(action == "wifi_on" ? "on" : "off")."
        case "show_desktop":
            _ = await Run.capture("/usr/bin/osascript", ["-e", "tell application \"System Events\" to key code 103"])
            return "Done."
        default:
            return "I can do: \(actions.joined(separator: ", "))."
        }
    }

    static func wifiDevice() async -> String {
        let out = await Run.capture("/usr/sbin/networksetup", ["-listallhardwareports"])
        var wifi = false
        for line in out.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { wifi = line.contains("Wi-Fi") || line.contains("AirPort") }
            if wifi, line.hasPrefix("Device:") { return line.replacingOccurrences(of: "Device:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        return "en0"
    }
}

public enum Apps {
    public static func running() -> String {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.localizedName }
            .sorted()
            .joined(separator: ", ")
    }

    @MainActor
    public static func quit(_ name: String) -> String {
        let match = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && ($0.localizedName?.caseInsensitiveCompare(name) == .orderedSame)
        }
        guard !match.isEmpty else { return "\(name) isn't open." }
        match.forEach { $0.terminate() }
        return "Asked \(name) to quit. It will ask about any unsaved work."
    }
}

public enum Shortcuts {
    public static func list() async -> String {
        let out = await Run.capture("/usr/bin/shortcuts", ["list"], timeout: 15)
        return out.isEmpty ? "No shortcuts found." : String(out.prefix(4000))
    }

    public static func run(_ name: String, input: String) async -> String {
        var args = ["run", name]
        var tmp: URL?
        if !input.isEmpty {
            let u = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-shortcut-\(UUID().uuidString).txt")
            try? input.write(to: u, atomically: true, encoding: .utf8)
            args += ["--input-path", u.path]
            tmp = u
        }
        let out = await Run.capture("/usr/bin/shortcuts", args, timeout: 120)
        if let tmp { try? FileManager.default.removeItem(at: tmp) }
        return out.isEmpty ? "Ran \u{201C}\(name)\u{201D}." : String(out.prefix(4000))
    }
}

public enum Files {
    /// Spotlight search across the home folder, skipping Library and hidden folders.
    public static func find(_ query: String, kind: String = "", limit: Int = 25) async -> String {
        var q = "kMDItemDisplayName == '*\(query.replacingOccurrences(of: "'", with: ""))*'cd"
        switch kind.lowercased() {
        case "pdf": q += " && kMDItemContentType == 'com.adobe.pdf'"
        case "image": q += " && kMDItemContentTypeTree == 'public.image'"
        case "video": q += " && kMDItemContentTypeTree == 'public.movie'"
        case "document": q += " && kMDItemContentTypeTree == 'public.content'"
        case "folder": q += " && kMDItemContentType == 'public.folder'"
        default: break
        }
        var out = await Run.capture("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), q], timeout: 15)
        if out.isEmpty {
            out = await Run.capture("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), query], timeout: 15)
        }
        let lib = NSHomeDirectory() + "/Library/"
        let hits = out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(lib) && !$0.contains("/.") }.prefix(limit)
        return hits.isEmpty ? "Nothing found for \u{201C}\(query)\u{201D}." : hits.joined(separator: "\n")
    }

    /// Text from PDFs, Word, RTF, HTML and plain text files.
    public static func text(of url: URL, limit: Int = 20_000) -> String? {
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let doc = PDFDocument(url: url) else { return nil }
            return String((doc.string ?? "").prefix(limit))
        case "docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "webarchive":
            guard let s = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) else { return nil }
            return String(s.string.prefix(limit))
        default:
            guard let data = try? Data(contentsOf: url), data.count < 5_000_000 else { return nil }
            return String(decoding: data.prefix(limit), as: UTF8.self)
        }
    }
}

public enum Web {
    /// Downloads a page and returns its readable text.
    public static func fetch(_ urlString: String) async -> String {
        guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return "Only http and https links can be read."
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 400 else { return "The page answered with error \(code)." }
            let type = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let raw = String(decoding: data.prefix(3_000_000), as: UTF8.self)
            let text = type.contains("html") || raw.lowercased().contains("<html") ? readable(raw) : raw
            return String(text.prefix(12_000))
        } catch {
            return "Couldn't load the page: \(error.localizedDescription)"
        }
    }

    /// Strips scripts, styles and tags, keeping the title and the visible words.
    public static func readable(_ html: String) -> String {
        var s = html
        let title = s.range(of: "<title[^>]*>(.*?)</title>", options: [.regularExpression, .caseInsensitive])
            .map { String(s[$0]).replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) } ?? ""
        for tag in ["script", "style", "noscript", "svg", "nav", "footer", "header", "form", "iframe"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: " ", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<(br|/p|/div|/li|/h[1-6]|/tr)[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (k, v) in ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&rsquo;": "'", "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&mdash;": "\u{2014}"] {
            s = s.replacingOccurrences(of: k, with: v)
        }
        let lines = s.split(separator: "\n").map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }.filter { $0.count > 1 }
        let body = lines.joined(separator: "\n")
        return title.isEmpty ? body : "Title: \(title.trimmingCharacters(in: .whitespacesAndNewlines))\n\(body)"
    }
}
