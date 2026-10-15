import Foundation
import AppKit

public struct ToolResult: Sendable {
    public var text: String
    public var screenshot = false
    public var finished: AgentOutcome?
    public init(_ text: String, screenshot: Bool = false, finished: AgentOutcome? = nil) {
        self.text = text
        self.screenshot = screenshot
        self.finished = finished
    }
}

public final class ToolBox: @unchecked Sendable {
    private let settings: JarvisSettings
    private let memory: MemoryStore
    private let confirm: @Sendable (String) async -> Bool
    private let notify: @Sendable (String, String) -> Void

    public init(settings: JarvisSettings, memory: MemoryStore,
                confirm: @escaping @Sendable (String) async -> Bool,
                notify: @escaping @Sendable (String, String) -> Void) {
        self.settings = settings
        self.memory = memory
        self.confirm = confirm
        self.notify = notify
    }

    // MARK: Declarations

    private static func fn(_ name: String, _ desc: String, _ props: [String: (String, String)] = [:], required: [String] = []) -> [String: Any] {
        var p: [String: Any] = [:]
        for (k, v) in props { p[k] = ["type": v.0, "description": v.1] }
        var d: [String: Any] = ["name": name, "description": desc]
        if !props.isEmpty { d["parameters"] = ["type": "OBJECT", "properties": p, "required": required] as [String: Any] }
        return d
    }

    public func declarations(screen: Bool) -> [[String: Any]] {
        var d: [[String: Any]] = [
            Self.fn("open_app", "Open or switch to a Mac app by name.", ["name": ("STRING", "App name, e.g. Safari")], required: ["name"]),
            Self.fn("open_url", "Open a URL in the default browser.", ["url": ("STRING", "Full URL")], required: ["url"]),
            Self.fn("clipboard_read", "Read the current clipboard text."),
            Self.fn("clipboard_write", "Replace the clipboard text.", ["text": ("STRING", "Text")], required: ["text"]),
            Self.fn("remember", "Save a durable fact about the user or their preferences.", ["fact": ("STRING", "Short fact")], required: ["fact"]),
            Self.fn("schedule", "Run a request automatically at a time of day, daily or on chosen weekdays.", [
                "prompt": ("STRING", "What Jarvis should do when it fires"),
                "time": ("STRING", "24-hour HH:mm"),
                "days": ("STRING", "Comma-separated weekday numbers, 1=Sunday..7=Saturday; omit for every day"),
            ], required: ["prompt", "time"]),
            Self.fn("list_schedules", "List scheduled automations."),
            Self.fn("cancel_schedule", "Remove a scheduled automation.", ["id": ("STRING", "Automation id")], required: ["id"]),
            Self.fn("set_timer", "Notify and speak after a delay.", ["seconds": ("INTEGER", "Delay"), "label": ("STRING", "What it is for")], required: ["seconds"]),
            Self.fn("read_file", "Read a text file from an allowed folder.", ["path": ("STRING", "File path")], required: ["path"]),
            Self.fn("list_folder", "List files in an allowed folder.", ["path": ("STRING", "Folder path")], required: ["path"]),
        ]
        if settings.shellEnabled {
            d.append(Self.fn("shell", "Run a shell command in a sandbox: no network, writes only to a scratch folder. Good for git status/log, grep, calculations, file inspection.", ["command": ("STRING", "zsh command")], required: ["command"]))
        }
        if settings.mailEnabled {
            d.append(Self.fn("mail_unread", "Read recent unread mail from the Mail app.", ["limit": ("INTEGER", "Max messages, default 5")]))
            d.append(Self.fn("mail_send", "Send an email with the Mail app. The user is asked to approve first.", [
                "to": ("STRING", "Recipient address"), "subject": ("STRING", "Subject"), "body": ("STRING", "Body text"),
            ], required: ["to", "subject", "body"]))
        }
        if screen {
            d.append(Self.fn("computer", "Control the mouse and keyboard on the user's Mac. Coordinates are on a 0-1000 grid over the latest screenshot (x left to right, y top to bottom).", [
                "action": ("STRING", "click, double_click, right_click, move, type, key, scroll, wait, or done"),
                "x": ("INTEGER", "0-1000"), "y": ("INTEGER", "0-1000"),
                "text": ("STRING", "Text to type, key combo like cmd+t, or the final summary for done"),
                "dy": ("INTEGER", "Scroll lines; negative scrolls down"),
                "success": ("BOOLEAN", "For done"),
                "risk": ("STRING", "none, sends, deletes, purchase, or credentials"),
                "intent": ("STRING", "One short sentence on what this step does"),
            ], required: ["action", "risk", "intent"]))
        }
        return d
    }

    /// The same tools in Anthropic's schema format.
    public func anthropicTools(screen: Bool) -> [[String: Any]] {
        func lower(_ v: Any) -> Any {
            if var d = v as? [String: Any] {
                if let ty = d["type"] as? String { d["type"] = ty.lowercased() }
                return d.mapValues(lower)
            }
            return v
        }
        return declarations(screen: screen).map { d in
            let params = (d["parameters"].map(lower) as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            return ["name": d["name"] as Any, "description": d["description"] as Any, "input_schema": params]
        }
    }

    // MARK: Execution

    public func execute(_ name: String, _ a: [String: Any], screen: CGSize) async -> ToolResult {
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        func int(_ k: String) -> Int? { (a[k] as? Int) ?? (a[k] as? Double).map(Int.init) }

        switch name {
        case "computer":
            return await computer(a, screen: screen)
        case "open_app":
            let ok = await MainActor.run { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", str("name")]
                return (try? p.run()) != nil
            }
            return ToolResult(ok ? "Opened." : "Couldn't open that app.", screenshot: true)
        case "open_url":
            guard let u = URL(string: str("url")), ["http", "https"].contains(u.scheme) else { return ToolResult("Only http and https links are allowed.") }
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
            return ToolResult("Opened.", screenshot: true)
        case "clipboard_read":
            let t = await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
            return ToolResult(t.isEmpty ? "(empty)" : String(t.prefix(6000)))
        case "clipboard_write":
            await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(str("text"), forType: .string) }
            return ToolResult("Copied.")
        case "remember":
            memory.addFact(str("fact"))
            return ToolResult("Saved.")
        case "schedule":
            let parts = str("time").split(separator: ":").compactMap { Int($0) }
            guard parts.count == 2, (0..<24).contains(parts[0]), (0..<60).contains(parts[1]) else { return ToolResult("Time must be HH:mm.") }
            let days = str("days").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.filter { (1...7).contains($0) }
            let auto = Automation(id: String(UUID().uuidString.prefix(6)), prompt: str("prompt"), hour: parts[0], minute: parts[1], days: days)
            memory.addAutomation(auto)
            return ToolResult("Scheduled \(auto.label) (id \(auto.id)).")
        case "list_schedules":
            let all = memory.automations
            return ToolResult(all.isEmpty ? "None." : all.map { "\($0.id): \($0.label) - \($0.prompt)" }.joined(separator: "\n"))
        case "cancel_schedule":
            memory.removeAutomation(str("id"))
            return ToolResult("Removed.")
        case "set_timer":
            let secs = max(1, int("seconds") ?? 60)
            let label = str("label").isEmpty ? "Timer" : str("label")
            let note = notify
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(secs)) { note("Jarvis", "\(label) is done.") }
            return ToolResult("Timer set for \(secs) seconds.")
        case "read_file":
            guard let url = allowed(str("path")) else { return ToolResult("That path isn't in an allowed folder.") }
            guard let data = try? Data(contentsOf: url), data.count < 2_000_000 else { return ToolResult("Couldn't read that file.") }
            let t = String(decoding: data.prefix(20_000), as: UTF8.self)
            return ToolResult(t)
        case "list_folder":
            guard let url = allowed(str("path")),
                  let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return ToolResult("That folder isn't allowed or doesn't exist.") }
            return ToolResult(items.sorted().prefix(100).joined(separator: "\n"))
        case "shell":
            guard settings.shellEnabled else { return ToolResult("Shell is turned off.") }
            return ToolResult(await Sandbox.run(str("command")))
        case "mail_unread":
            guard settings.mailEnabled else { return ToolResult("Mail is turned off.") }
            return ToolResult(await Mail.unread(limit: min(max(int("limit") ?? 5, 1), 15)))
        case "mail_send":
            guard settings.mailEnabled else { return ToolResult("Mail is turned off.") }
            guard await confirm("Send email to \(str("to"))?\nSubject: \(str("subject"))\n\n\(str("body").prefix(400))") else {
                return ToolResult("The user declined, so nothing was sent.")
            }
            return ToolResult(await Mail.send(to: str("to"), subject: str("subject"), body: str("body")))
        default:
            return ToolResult("Unknown tool.")
        }
    }

    private func allowed(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        for f in settings.allowedFolders {
            let root = URL(fileURLWithPath: (f as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath().path
            if url.path == root || url.path.hasPrefix(root + "/") { return url }
        }
        return nil
    }

    private func computer(_ a: [String: Any], screen: CGSize) async -> ToolResult {
        let action = a["action"] as? String ?? ""
        let intent = a["intent"] as? String ?? action
        let risk = a["risk"] as? String ?? "none"

        if action == "done" {
            return ToolResult("", finished: AgentOutcome(success: a["success"] as? Bool ?? true, summary: a["text"] as? String ?? "Done."))
        }
        if settings.confirmRisky, risk != "none", !(await confirm("\(intent) (\(risk))")) {
            return ToolResult("The user declined this step. Stop and report.", finished: AgentOutcome(success: false, summary: "Okay, I cancelled that."))
        }
        func num(_ k: String) -> Double? { (a[k] as? Double) ?? (a[k] as? Int).map(Double.init) }
        func point() -> CGPoint? {
            guard let x = num("x"), let y = num("y") else { return nil }
            return CGPoint(x: min(max(x, 0), 1000) / 1000 * screen.width, y: min(max(y, 0), 1000) / 1000 * screen.height)
        }
        switch action {
        case "click", "double_click", "right_click":
            guard let p = point() else { return ToolResult("Missing x/y.") }
            await Input.click(at: p, right: action == "right_click", count: action == "double_click" ? 2 : 1)
            return ToolResult("Clicked.", screenshot: true)
        case "move":
            guard let p = point() else { return ToolResult("Missing x/y.") }
            await Input.move(to: p)
            return ToolResult("Moved.", screenshot: true)
        case "type":
            await Input.type(a["text"] as? String ?? "")
            return ToolResult("Typed.", screenshot: true)
        case "key":
            let ok = await Input.key(a["text"] as? String ?? "")
            return ToolResult(ok ? "Pressed." : "Unknown key.", screenshot: true)
        case "scroll":
            Input.scroll(dy: Int(num("dy") ?? 0))
            return ToolResult("Scrolled.", screenshot: true)
        case "wait":
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return ToolResult("Waited.", screenshot: true)
        default:
            return ToolResult("Unknown action.")
        }
    }
}
