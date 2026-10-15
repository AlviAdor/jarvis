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
    private let onAction: @Sendable (ActionEvent) -> Void
    private let mcp: [MCPTool]
    private let search: (@Sendable (String) async -> String)?
    private let setSetting: (@Sendable (String, String) async -> String)?
    /// What the user asked, so only the tool groups that could matter are sent (smaller, faster requests).
    private let hint: String
    /// Set once untrusted content (mail, files, web pages, calendar invites, command output...) has entered the conversation.
    private var tainted: Bool {
        get { taintLock.withLock { _tainted } }
        set { taintLock.withLock { _tainted = newValue } }
    }
    private var _tainted = false
    private let taintLock = NSLock()

    /// Read-only lookups that can safely run at the same time when the model asks for several at once.
    public static let parallelSafe: Set<String> = [
        "web_search", "fetch_url", "mac_status", "read_feed", "find_files", "read_file", "list_folder",
        "running_apps", "contacts_search", "today_brief",
    ]

    public init(settings: JarvisSettings, memory: MemoryStore,
                confirm: @escaping @Sendable (String) async -> Bool,
                notify: @escaping @Sendable (String, String) -> Void,
                onAction: @escaping @Sendable (ActionEvent) -> Void = { _ in },
                mcp: [MCPTool] = [],
                search: (@Sendable (String) async -> String)? = nil,
                setSetting: (@Sendable (String, String) async -> String)? = nil,
                hint: String = "") {
        self.hint = hint
        self.settings = settings
        self.memory = memory
        self.confirm = confirm
        self.notify = notify
        self.onAction = onAction
        self.mcp = mcp
        self.search = search
        self.setSetting = setSetting
    }

    /// Agents use this to show steps that aren't tool calls, such as a web search.
    public func report(_ e: ActionEvent) { onAction(e) }

    /// Asks the user to approve something, with the same dialog as risky tool steps.
    public func ask(_ question: String) async -> Bool { await confirm(question) }

    private func mcpTool(_ name: String) -> MCPTool? {
        name.hasPrefix("mcp_") ? mcp.first { $0.exposedName == name } : nil
    }

    /// Tools whose results come from outside the user's own instructions.
    static let readsOutside: Set<String> = [
        "mail_unread", "read_file", "list_folder", "clipboard_read", "shell", "fetch_url", "web_search",
        "calendar", "notes", "find_files", "shortcuts", "run_applescript", "ui", "browser", "read_feed", "http_request", "sqlite",
    ]

    static let groupWords: [String: [String]] = [
        "dev": ["git", "commit", "repo", "pull request", " pr ", " prs", "test", "lint", "format", "build", "code", "branch", "diff",
                "push", "project", "bug", "compile", "merge"],
        "http": ["api", "endpoint", "http", "request", "curl", "json", "webhook", "localhost", "postman", "status code"],
        "sqlite": ["sqlite", ".db", "database", "sql", "table", "query"],
        "music": ["spotify", "play", "song", "music", "playlist", "track", "album", "artist", "volume", "sound", "audio", "speaker",
                  "headphone", "airpods", "output", "microphone", " mic", "noise", "lofi", "pause", "skip", "next"],
        "docs": ["proposal", "contract", "nda", "agreement", "document", "report", "save", "case study", "cover letter", "invoice",
                 "draft", "word", "docx", "status update", "release notes", "portfolio", "letter", "template", "email"],
        "feeds": ["feed", "rss", "jobs", "job ", "upwork", "fiverr", "linkedin", "freelance", "news", "blog", "postings", "gig"],
    ]

    /// Whether a group of tools could matter for this request. With no hint (automations), everything is offered.
    func wants(_ group: String) -> Bool {
        guard !hint.isEmpty else { return true }
        let s = " " + hint.lowercased() + " "
        return Self.groupWords[group]?.contains { s.contains($0) } ?? true
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
            Self.fn("quit_app", "Quit a running app by name.", ["name": ("STRING", "App name")], required: ["name"]),
            Self.fn("running_apps", "List the apps that are open."),
            Self.fn("open_url", "Open a URL in the default browser.", ["url": ("STRING", "Full URL")], required: ["url"]),
            Self.fn("clipboard_read", "Read the current clipboard text."),
            Self.fn("clipboard_write", "Replace the clipboard text.", ["text": ("STRING", "Text")], required: ["text"]),
            Self.fn("type_text", "Type text into the app in front, as if from the keyboard. For dictation or filling the focused field.",
                    ["text": ("STRING", "Text to type")], required: ["text"]),
            Self.fn("remember", "Save a durable fact about the user or their preferences.", ["fact": ("STRING", "Short fact")], required: ["fact"]),
            Self.fn("forget", "Forget remembered facts that contain these words.", ["words": ("STRING", "Words to match")], required: ["words"]),
            Self.fn("schedule", "Run a request automatically at a time of day, daily or on chosen weekdays.", [
                "prompt": ("STRING", "What Jarvis should do when it fires"),
                "time": ("STRING", "24-hour HH:mm"),
                "days": ("STRING", "Comma-separated weekday numbers, 1=Sunday..7=Saturday; omit for every day"),
            ], required: ["prompt", "time"]),
            Self.fn("list_schedules", "List scheduled automations."),
            Self.fn("cancel_schedule", "Remove a scheduled automation.", ["id": ("STRING", "Automation id")], required: ["id"]),
            Self.fn("set_timer", "Notify and speak after a delay.", ["seconds": ("INTEGER", "Delay"), "label": ("STRING", "What it is for")], required: ["seconds"]),
            Self.fn("read_file", "Read a file from an allowed folder. Handles text, PDF, Word, RTF and HTML.", ["path": ("STRING", "File path")], required: ["path"]),
            Self.fn("list_folder", "List files in an allowed folder.", ["path": ("STRING", "Folder path")], required: ["path"]),
            Self.fn("find_files", "Find files and folders in the user's home folder with Spotlight, by name or by what's inside them (code, notes, documents).", [
                "query": ("STRING", "Part of the name, or words inside the file"), "kind": ("STRING", "Optional: pdf, image, video, document or folder"),
                "in_contents": ("BOOLEAN", "Search inside files instead of names"), "folder": ("STRING", "Optional folder to search in"),
            ], required: ["query"]),
            Self.fn("open_file", "Open a file with its default app, or reveal it in Finder.", [
                "path": ("STRING", "File path in the home folder"), "reveal": ("BOOLEAN", "Show in Finder instead of opening"),
            ], required: ["path"]),
            Self.fn("mac_status", "Report the Mac's health: CPU, memory, storage, battery health and cycles, temperature state, network and the busiest apps.",
                    ["focus": ("STRING", "all, cpu, memory, storage, battery, network or processes")]),
            Self.fn("today_brief", "Gather today's calendar, due reminders and the Mac's condition for a short briefing."),
            Self.fn("update_setting", "Change one of Jarvis's own settings when the user asks.", [
                "name": ("STRING", "speakReplies, voiceRate (0.3-0.65), voiceEngine (apple|gemini), geminiVoice, theme (dark|light|system), modelChoice (auto|lite|flash|pro), wakeWordEnabled, narrateActions, showHighlights, reduceMotion, healthAlerts, showTelemetry, userName"),
                "value": ("STRING", "New value"),
            ], required: ["name", "value"]),
        ]
        if search != nil, settings.searchEnabled {
            d.append(Self.fn("web_search", "Search the web for current information and get a sourced answer.", ["query": ("STRING", "Search query")], required: ["query"]))
        }
        if settings.webReadEnabled {
            d.append(Self.fn("fetch_url", "Read the text of a web page.", ["url": ("STRING", "http or https URL")], required: ["url"]))
        }
        if settings.appControlEnabled {
            d.append(Self.fn("ui", "Operate apps through their real controls (Accessibility), without screenshots: list the front window's buttons, fields and menus, press one, fill a field, choose a menu item, switch apps, or act on windows. Prefer this over the screen.", [
                "action": ("STRING", "list, press, set_text, menu, focus or window"),
                "target": ("STRING", "For press/set_text: a #number from the last list, or the control's label"),
                "text": ("STRING", "For set_text"),
                "path": ("STRING", "For menu: e.g. File > Export as PDF…"),
                "app": ("STRING", "App name; default is the app in front"),
                "window_action": ("STRING", "For window: minimize, close, zoom, fullscreen, hide or hide_others"),
            ], required: ["action"]))
            d.append(Self.fn("ai_app", "Use another AI assistant the way the user would: open ChatGPT, Claude, Gemini, Grok, Perplexity or Copilot (the desktop app if installed, otherwise the website), type a prompt into its message box visibly, send it, and optionally read the reply.", [
                "app": ("STRING", "chatgpt, claude, gemini, grok, perplexity or copilot"),
                "prompt": ("STRING", "A clear, well-written prompt, as the user"),
                "send": ("BOOLEAN", "Press send after typing (default true)"),
                "read_reply": ("BOOLEAN", "Wait for the answer and return it"),
            ], required: ["app", "prompt"]))
            d.append(Self.fn("run_applescript", "Run AppleScript to automate Mac apps (Finder, Safari, Music, Mail, Notes, System Events and more). The script is shown to the user; risky ones ask first.", [
                "script": ("STRING", "AppleScript source"), "purpose": ("STRING", "One short sentence on what it does"),
            ], required: ["script", "purpose"]))
            d.append(Self.fn("browser", "The user's web browser: the page they're on, their open tabs, reading the current page's text, or opening a link.", [
                "action": ("STRING", "current, tabs, read or open"), "url": ("STRING", "For open"),
            ], required: ["action"]))
            d.append(Self.fn("files", "Move, copy, rename, zip or unzip the user's files, or make a folder. Only inside the home folder; nothing is overwritten.", [
                "action": ("STRING", "move, copy, rename, make_folder, zip or unzip"),
                "from": ("STRING", "Source path"), "to": ("STRING", "Destination folder or path"), "name": ("STRING", "New name, or folder name"),
            ], required: ["action"]))
        }
        if settings.workToolsEnabled {
            if wants("dev") {
                d.append(Self.fn("dev", "Work with a code project: git status, log, branches, diff, commit (write the message from the diff), push, GitHub pull request status, and running its tests, formatter or linter.", [
                    "action": ("STRING", "status, log, branches, diff, commit, push, pr_status, test, format or lint"),
                    "path": ("STRING", "The project folder"), "message": ("STRING", "For commit"),
                ], required: ["action", "path"]))
            }
            if wants("http") {
                d.append(Self.fn("http_request", "Call an API or web endpoint (also localhost) and see the status, type and body, like an API client.", [
                    "method": ("STRING", "GET, POST, PUT, PATCH or DELETE"), "url": ("STRING", "Full URL"),
                    "headers": ("STRING", "One 'Name: value' per line"), "body": ("STRING", "Request body, often JSON"),
                ], required: ["method", "url"]))
            }
            if wants("sqlite") {
                d.append(Self.fn("sqlite", "Query a SQLite database file. Reading is free; changes ask the user first.", [
                    "path": ("STRING", "Database file"), "query": ("STRING", "SQL"),
                ], required: ["path", "query"]))
            }
            if wants("docs") {
                d.append(Self.fn("save_document", "Save writing (proposals, contracts, NDAs, reports, status updates, case studies, cover letters) as a document in ~/Documents/Jarvis.", [
                    "name": ("STRING", "File name without extension"), "format": ("STRING", "docx (default), rtf, md, txt or html"),
                    "content": ("STRING", "The document in Markdown"),
                ], required: ["name", "content"]))
                d.append(Self.fn("mail_draft", "Open a Mail draft for the user to check and send, optionally with a file attached.", [
                    "to": ("STRING", "Recipient"), "subject": ("STRING", "Subject"), "body": ("STRING", "Message"), "attachment": ("STRING", "Optional file path"),
                ], required: ["subject", "body"]))
            }
            if wants("feeds") {
                d.append(Self.fn("read_feed", "Read the latest items of an RSS or Atom feed (job boards, blogs, news).", ["url": ("STRING", "Feed URL")], required: ["url"]))
            }
        }
        if settings.controlEnabled, wants("music") {
            d.append(Self.fn("spotify", "Control Spotify: what's playing, play a spotify: link or resume, pause, next, previous, shuffle, repeat, volume, or open a search.", [
                "action": ("STRING", "now_playing, play, pause, play_pause, next, previous, shuffle, repeat, volume or search"),
                "value": ("STRING", "A spotify: link, a volume 0-100, or search words"),
            ], required: ["action"]))
            d.append(Self.fn("audio", "Sound devices and focus noise: list devices, switch the speakers or microphone, play white, pink or brown noise, or stop it.", [
                "action": ("STRING", "devices, use_output, use_input, noise or stop_noise"),
                "name": ("STRING", "Device name for use_output/use_input"), "type": ("STRING", "white, pink or brown"), "volume": ("NUMBER", "0.05 to 1"),
            ], required: ["action"]))
        }
        if settings.cleanupEnabled {
            d.append(Self.fn("disk", "See what uses disk space and free it up. Always start with report. Deleting and trashing ask the user first.", [
                "action": ("STRING", "report, large_files, old_downloads, duplicates, clean or trash"),
                "target": ("STRING", "For clean: \(DiskCare.cleanTargets.joined(separator: ", "))"),
                "folder": ("STRING", "For duplicates: folder path, default ~/Downloads"),
                "paths": ("STRING", "For trash: file paths, one per line"),
                "days": ("INTEGER", "For old_downloads: untouched for this many days, default 60"),
                "min_mb": ("INTEGER", "For large_files: minimum size in MB, default 500"),
            ], required: ["action"]))
            d.append(Self.fn("organize_folder", "Tidy a folder by sorting its loose files into subfolders by kind (Images, PDFs, Installers...). Preview first; apply asks the user; undo restores the last change.", [
                "folder": ("STRING", "Folder path, e.g. ~/Downloads or ~/Desktop"),
                "action": ("STRING", "preview, apply or undo"),
            ], required: ["action"]))
        }
        if settings.calendarEnabled {
            d.append(Self.fn("calendar", "Read or change the user's calendar.", [
                "action": ("STRING", "list, create or delete"),
                "days": ("INTEGER", "For list: how many days from today, default 1"),
                "from": ("STRING", "For list: start date yyyy-MM-dd, default today"),
                "title": ("STRING", "Event title"), "start": ("STRING", "yyyy-MM-dd HH:mm"), "end": ("STRING", "yyyy-MM-dd HH:mm"),
                "location": ("STRING", "Location"), "notes": ("STRING", "Notes"), "id": ("STRING", "Event id for delete"),
            ], required: ["action"]))
            d.append(Self.fn("reminders", "Read, add or complete reminders.", [
                "action": ("STRING", "list, create or complete"),
                "title": ("STRING", "Reminder text"), "due": ("STRING", "yyyy-MM-dd HH:mm or HH:mm today"),
                "list": ("STRING", "Reminders list name"), "notes": ("STRING", "Notes"), "id": ("STRING", "Reminder id for complete"),
            ], required: ["action"]))
        }
        if settings.contactsEnabled {
            d.append(Self.fn("contacts_search", "Look up a person's phone numbers, email addresses and birthday.", ["query": ("STRING", "Name")], required: ["query"]))
        }
        if settings.notesEnabled {
            d.append(Self.fn("notes", "Create or search notes in Apple Notes.", [
                "action": ("STRING", "create or search"), "title": ("STRING", "Note title"), "body": ("STRING", "Note text"), "query": ("STRING", "Search words"),
            ], required: ["action"]))
        }
        if settings.messagesEnabled {
            d.append(Self.fn("send_message", "Send an iMessage. The user approves it first.", [
                "to": ("STRING", "Phone number or email address"), "text": ("STRING", "Message"),
            ], required: ["to", "text"]))
        }
        if settings.controlEnabled {
            d.append(Self.fn("mac_control", "Control media, sound, brightness, appearance, Wi-Fi and the screen.", [
                "action": ("STRING", MacControl.actions.joined(separator: ", ")),
                "value": ("STRING", "Volume 0-100 for set_volume, steps for up/down, or a song/artist for play_music"),
            ], required: ["action"]))
        }
        if settings.shortcutsEnabled {
            d.append(Self.fn("shortcuts", "List or run the user's Shortcuts (the Shortcuts app).", [
                "action": ("STRING", "list or run"), "name": ("STRING", "Shortcut name"), "input": ("STRING", "Optional text input"),
            ], required: ["action"]))
        }
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
        } else {
            d.append(Self.fn("use_screen", "Hand the job over to screen control when it can only be done by looking at and clicking in apps.",
                             ["reason": ("STRING", "Why the screen is needed")], required: ["reason"]))
        }
        for t in mcp {
            var decl: [String: Any] = ["name": t.exposedName, "description": "[\(t.server)] \(t.description.prefix(500))"]
            let params = SchemaConvert.gemini(t.schema)
            if let props = params["properties"] as? [String: Any], !props.isEmpty { decl["parameters"] = params }
            d.append(decl)
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
            var params = (d["parameters"].map(lower) as? [String: Any]) ?? ["type": "object", "properties": [String: Any]()]
            // Tool servers already speak JSON Schema, which Claude takes as is.
            if let name = d["name"] as? String, let t = mcpTool(name) {
                params = t.schema
                params["type"] = "object"
            }
            return ["name": d["name"] as Any, "description": d["description"] as Any, "input_schema": params]
        }
    }

    // MARK: Execution

    public func execute(_ name: String, _ a: [String: Any], screen: CGSize) async -> ToolResult {
        if name == "computer", a["action"] as? String == "done" { return await run(name, a, screen: screen) }
        if name == "use_screen" { return await run(name, a, screen: screen) }

        let id = UUID()
        let (title, detail, point, icon) = describe(name, a, screen: screen)
        onAction(ActionEvent(id: id, title: title, detail: detail, point: point, state: .running, icon: icon))

        if settings.stepByStep, !(await confirm("Next step: \(title)")) {
            onAction(ActionEvent(id: id, title: title, detail: "Skipped", point: nil, state: .failed, icon: icon))
            return ToolResult("The user declined this step.", finished: AgentOutcome(success: false, summary: "Okay, I stopped."))
        }

        let res = await run(name, a, screen: screen)
        let outside = Self.readsOutside.contains(name) || mcpTool(name) != nil
        if outside { tainted = true }

        let failed = ["Couldn't", "That ", "Unknown", "Missing", "Only ", "Shell is", "Mail is", "Error:", "The user declined"].contains { res.text.hasPrefix($0) }
        var shown = outside ? String(res.text.prefix(500)) : (detail ?? String(res.text.prefix(300)))
        if name == "shell" { shown = "$ \(a["command"] as? String ?? "")\n\(res.text.prefix(500))" }
        if ["disk", "organize_folder", "mac_status", "mac_control", "quit_app", "calendar", "reminders"].contains(name) { shown = String(res.text.prefix(500)) }
        onAction(ActionEvent(id: id, title: title, detail: shown, point: point, state: failed ? .failed : .done, icon: icon))
        return res
    }

    private func describe(_ name: String, _ a: [String: Any], screen: CGSize) -> (String, String?, CGPoint?, String) {
        func s(_ k: String) -> String { a[k] as? String ?? "" }
        func n(_ k: String) -> Double? { (a[k] as? Double) ?? (a[k] as? Int).map(Double.init) }
        func file(_ k: String) -> String { (s(k) as NSString).lastPathComponent }
        switch name {
        case "open_app": return ("Opening \(s("name"))", nil, nil, "app.badge")
        case "ui":
            switch s("action") {
            case "press": return ("Pressing \(s("target"))", s("app").isEmpty ? nil : s("app"), nil, "hand.tap")
            case "set_text": return ("Filling \(s("target"))", s("text"), nil, "character.cursor.ibeam")
            case "menu": return ("Choosing \(s("path"))", nil, nil, "filemenu.and.selection")
            case "focus": return ("Switching to \(s("app"))", nil, nil, "macwindow.on.rectangle")
            case "window": return ("\(s("window_action").capitalized) window", nil, nil, "macwindow")
            default: return ("Looking at \(s("app").isEmpty ? "the app in front" : s("app"))", nil, nil, "list.bullet.rectangle")
            }
        case "run_applescript": return (s("purpose").isEmpty ? "Running AppleScript" : s("purpose"), s("script"), nil, "applescript")
        case "ai_app": return ("Asking \(AIApps.target(s("app"))?.name ?? s("app"))", s("prompt"), nil, "bubble.left.and.text.bubble.right")
        case "browser":
            switch s("action") {
            case "open": return ("Opening \(URL(string: s("url"))?.host ?? "a link")", s("url"), nil, "safari")
            case "tabs": return ("Checking your tabs", nil, nil, "rectangle.stack")
            case "read": return ("Reading the page you're on", nil, nil, "doc.richtext")
            default: return ("Checking your browser", nil, nil, "safari")
            }
        case "files":
            let what = (s("from") as NSString).lastPathComponent
            switch s("action") {
            case "make_folder": return ("Making folder \(s("name"))", nil, nil, "folder.badge.plus")
            case "zip": return ("Zipping \(what)", nil, nil, "doc.zipper")
            case "unzip": return ("Unzipping \(what)", nil, nil, "doc.zipper")
            default: return ("\(s("action").capitalized) \(what)", s("to").isEmpty ? s("name") : s("to"), nil, "folder")
            }
        case "quit_app": return ("Quitting \(s("name"))", nil, nil, "xmark.app")
        case "running_apps": return ("Checking open apps", nil, nil, "square.grid.2x2")
        case "open_url": return ("Opening \(URL(string: s("url"))?.host ?? "a link")", s("url"), nil, "safari")
        case "clipboard_read": return ("Reading the clipboard", nil, nil, "doc.on.clipboard")
        case "clipboard_write": return ("Copying to the clipboard", nil, nil, "doc.on.clipboard")
        case "type_text": return ("Typing", s("text"), nil, "keyboard")
        case "remember": return ("Remembering that", s("fact"), nil, "brain")
        case "forget": return ("Forgetting", s("words"), nil, "brain")
        case "schedule": return ("Scheduling for \(s("time"))", s("prompt"), nil, "calendar.badge.clock")
        case "list_schedules": return ("Checking your automations", nil, nil, "clock")
        case "cancel_schedule": return ("Cancelling an automation", nil, nil, "clock.badge.xmark")
        case "set_timer": return ("Setting a timer", nil, nil, "timer")
        case "read_file": return ("Reading \(file("path"))", nil, nil, "doc.text")
        case "list_folder": return ("Looking in \(file("path"))", nil, nil, "folder")
        case "find_files": return ("Searching your files", "\u{201C}\(s("query"))\u{201D}", nil, "magnifyingglass")
        case "dev": return ("Git: \(s("action").replacingOccurrences(of: "_", with: " "))", (s("path") as NSString).lastPathComponent, nil, "chevron.left.forwardslash.chevron.right")
        case "http_request": return ("\(s("method").uppercased()) \(URL(string: s("url"))?.host ?? "request")", s("url"), nil, "network")
        case "sqlite": return ("Querying \((s("path") as NSString).lastPathComponent)", s("query"), nil, "cylinder")
        case "save_document": return ("Saving \(s("name"))", nil, nil, "doc.badge.plus")
        case "mail_draft": return ("Drafting an email", s("subject"), nil, "envelope.badge")
        case "read_feed": return ("Reading \(URL(string: s("url"))?.host ?? "a feed")", nil, nil, "dot.radiowaves.up.forward")
        case "spotify": return ("Spotify: \(s("action").replacingOccurrences(of: "_", with: " "))", s("value").isEmpty ? nil : s("value"), nil, "music.note")
        case "audio": return (s("action") == "noise" ? "Playing \(s("type").isEmpty ? "pink" : s("type")) noise" : "Sound: \(s("action").replacingOccurrences(of: "_", with: " "))", s("name").isEmpty ? nil : s("name"), nil, "speaker.wave.2")
        case "open_file": return ((a["reveal"] as? Bool ?? false) ? "Showing \(file("path")) in Finder" : "Opening \(file("path"))", nil, nil, "doc")
        case "mac_status": return ("Checking your Mac", nil, nil, "gauge.with.dots.needle.67percent")
        case "today_brief": return ("Preparing your briefing", nil, nil, "sun.max")
        case "update_setting": return ("Changing a setting", "\(s("name")) → \(s("value"))", nil, "slider.horizontal.3")
        case "web_search": return ("Searching the web", "\u{201C}\(s("query"))\u{201D}", nil, "globe")
        case "fetch_url": return ("Reading \(URL(string: s("url"))?.host ?? "a page")", s("url"), nil, "doc.richtext")
        case "disk":
            switch s("action") {
            case "clean": return ("Cleaning \(s("target").replacingOccurrences(of: "_", with: " "))", nil, nil, "sparkles")
            case "trash": return ("Moving files to the Trash", nil, nil, "trash")
            case "large_files": return ("Finding large files", nil, nil, "externaldrive")
            case "duplicates": return ("Finding duplicate files", nil, nil, "square.on.square")
            case "old_downloads": return ("Finding old downloads", nil, nil, "arrow.down.circle")
            default: return ("Analysing disk usage", nil, nil, "internaldrive")
            }
        case "organize_folder":
            let f = s("folder").isEmpty ? "Downloads" : file("folder")
            return (s("action") == "undo" ? "Undoing the last tidy-up" : "Organising \(f)", nil, nil, "folder.badge.gearshape")
        case "calendar":
            return (s("action") == "create" ? "Adding \u{201C}\(s("title"))\u{201D}" : s("action") == "delete" ? "Removing an event" : "Checking your calendar", nil, nil, "calendar")
        case "reminders":
            return (s("action") == "create" ? "Adding a reminder" : s("action") == "complete" ? "Completing a reminder" : "Checking reminders", s("title").isEmpty ? nil : s("title"), nil, "checklist")
        case "contacts_search": return ("Looking up \(s("query"))", nil, nil, "person.crop.circle")
        case "notes": return (s("action") == "create" ? "Writing a note" : "Searching notes", s("action") == "create" ? s("title") : s("query"), nil, "note.text")
        case "send_message": return ("Messaging \(s("to"))", s("text"), nil, "message")
        case "mac_control": return (s("action").replacingOccurrences(of: "_", with: " ").capitalized, s("value").isEmpty ? nil : s("value"), nil, "slider.horizontal.below.square.filled.and.square")
        case "shortcuts": return (s("action") == "run" ? "Running the \u{201C}\(s("name"))\u{201D} shortcut" : "Listing your shortcuts", nil, nil, "square.stack.3d.up")
        case "shell": return ("Running in Terminal", "$ " + s("command"), nil, "terminal")
        case "mail_unread": return ("Checking your mail", nil, nil, "envelope")
        case "mail_send": return ("Sending an email to \(s("to"))", s("subject"), nil, "paperplane")
        case "computer":
            var p: CGPoint?
            if let x = n("x"), let y = n("y") {
                p = CGPoint(x: min(max(x, 0), 1000) / 1000 * screen.width, y: min(max(y, 0), 1000) / 1000 * screen.height)
            }
            let intent = s("intent")
            let icon: String
            switch s("action") {
            case "type", "key": icon = "keyboard"
            case "scroll": icon = "scroll"
            case "wait": icon = "hourglass"
            default: icon = "cursorarrow.click.2"
            }
            return (intent.isEmpty ? s("action").capitalized : intent, s("action") == "type" ? s("text") : nil, p, icon)
        default:
            if let t = mcpTool(name) {
                let args = (try? JSONSerialization.data(withJSONObject: a, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) }
                return ("Using \(t.server): \(t.name)", args.map { String($0.prefix(300)) }, nil, "puzzlepiece.extension")
            }
            return (name, nil, nil, "gearshape")
        }
    }

    private func run(_ name: String, _ a: [String: Any], screen: CGSize) async -> ToolResult {
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        func int(_ k: String) -> Int? { (a[k] as? Int) ?? (a[k] as? Double).map(Int.init) ?? (a[k] as? String).flatMap { Int($0) } }
        func bool(_ k: String) -> Bool { (a[k] as? Bool) ?? ((a[k] as? String)?.lowercased() == "true") }
        func ask(_ q: String) async -> Bool { await confirm(q) }

        switch name {
        case "computer":
            return await computer(a, screen: screen)
        case "use_screen":
            return ToolResult("", finished: AgentOutcome(success: false, summary: str("reason"), needsScreen: true))
        case "open_app":
            let app = str("name")
            let ok = await MainActor.run { () -> Bool in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                p.arguments = ["-a", app]
                return (try? p.run()) != nil
            }
            return ToolResult(ok ? "Opened." : "Couldn't open that app.", screenshot: true)
        case "quit_app":
            if tainted, !(await ask("Quit \(str("name"))?")) { return ToolResult("The user declined.") }
            let app = str("name")
            return ToolResult(await MainActor.run { Apps.quit(app) })
        case "running_apps":
            return ToolResult(Apps.running())
        case "ui":
            let app = str("app").isEmpty ? nil : str("app")
            switch str("action") {
            case "press":
                let t = str("target").lowercased()
                if settings.confirmRisky || tainted, ["send", "delete", "buy", "pay", "purchase", "submit", "remove", "erase", "transfer", "confirm"].contains(where: t.contains),
                   !(await ask("Press \u{201C}\(str("target"))\u{201D}?")) { return ToolResult("The user declined.") }
                return ToolResult(await UIControl.press(str("target"), app: app), screenshot: true)
            case "set_text":
                if tainted, !(await ask("Type into \u{201C}\(str("target"))\u{201D}?\n\n\(str("text").prefix(200))")) { return ToolResult("The user declined.") }
                return ToolResult(await UIControl.setText(str("target"), str("text"), app: app), screenshot: true)
            case "menu":
                return ToolResult(await UIControl.menu(str("path"), app: app), screenshot: true)
            case "focus":
                let name = str("app")
                return ToolResult(await MainActor.run { UIControl.focus(name) }, screenshot: true)
            case "window":
                return ToolResult(await UIControl.window(str("window_action"), app: app), screenshot: true)
            default:
                return ToolResult(UIControl.list(app: app))
            }
        case "ai_app":
            guard let t = AIApps.target(str("app")) else { return ToolResult("Unknown assistant. Use chatgpt, claude, gemini, grok, perplexity or copilot.") }
            let prompt = str("prompt")
            let submit = (a["send"] as? Bool) ?? true
            let sent = await AIApps.send(t, prompt: prompt, submit: submit)
            guard submit, bool("read_reply"), sent.hasPrefix("Typed") else { return ToolResult(sent, screenshot: true) }
            tainted = true
            return ToolResult(sent + "\n\n\(t.name) replied:\n" + (await AIApps.readReply(after: prompt)))
        case "run_applescript":
            let script = str("script")
            let mode = settings.scriptConfirm
            if mode == "always" || (mode == "risky" && (Scripting.isRisky(script) || tainted)) {
                guard await ask("Run this AppleScript?\n\(str("purpose"))\n\n\(script.prefix(600))") else { return ToolResult("The user declined.") }
            }
            return ToolResult(await Scripting.run(script), screenshot: true)
        case "browser":
            switch str("action") {
            case "tabs": return ToolResult(await Browser.tabs())
            case "open": return ToolResult(await Browser.open(str("url")), screenshot: true)
            case "read":
                let cur = await Browser.current()
                guard let url = cur.split(separator: "\n").last.map(String.init), url.hasPrefix("http") else { return ToolResult(cur) }
                return ToolResult(cur + "\n\n" + (await Web.fetch(url)))
            default: return ToolResult(await Browser.current())
            }
        case "files":
            if tainted, !(await ask("\(str("action").capitalized) \((str("from") as NSString).lastPathComponent)?")) { return ToolResult("The user declined.") }
            return ToolResult(await FileOps.perform(str("action"), from: str("from"), to: str("to"), name: str("name")))
        case "open_url":
            guard let u = URL(string: str("url")), ["http", "https"].contains(u.scheme) else { return ToolResult("Only http and https links are allowed.") }
            if tainted, !(await ask("Open \(u.absoluteString)? This came after reading content Jarvis can't fully trust.")) {
                return ToolResult("The user declined.")
            }
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
            return ToolResult("Opened.", screenshot: true)
        case "clipboard_read":
            let t = await MainActor.run { NSPasteboard.general.string(forType: .string) ?? "" }
            return ToolResult(t.isEmpty ? "(empty)" : String(t.prefix(6000)))
        case "clipboard_write":
            let text = str("text")
            await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
            return ToolResult("Copied.")
        case "type_text":
            guard (try? Permissions.ensureAccessibility()) != nil else { return ToolResult("Couldn't type: Accessibility permission is off.") }
            if tainted, !(await ask("Type this into the app in front?\n\n\(str("text").prefix(300))")) { return ToolResult("The user declined.") }
            await Input.type(str("text"))
            return ToolResult("Typed.")
        case "remember":
            memory.addFact(str("fact"))
            return ToolResult("Saved.")
        case "forget":
            let words = str("words").lowercased()
            let hits = memory.facts.filter { $0.lowercased().contains(words) }
            hits.forEach { memory.removeFact($0) }
            return ToolResult(hits.isEmpty ? "Nothing remembered matches that." : "Forgot \(hits.count) fact\(hits.count == 1 ? "" : "s").")
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
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(secs)) { note("Timer", "\(label) is done.") }
            return ToolResult("Timer set for \(secs) seconds.")
        case "read_file":
            guard let url = allowed(str("path")) else { return ToolResult("That path isn't in an allowed folder.") }
            guard let t = Files.text(of: url) else { return ToolResult("Couldn't read that file.") }
            return ToolResult(t.isEmpty ? "(the file has no readable text)" : t)
        case "list_folder":
            guard let url = allowed(str("path")),
                  let items = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return ToolResult("That folder isn't allowed or doesn't exist.") }
            return ToolResult(items.filter { !$0.hasPrefix(".") }.sorted().prefix(150).joined(separator: "\n"))
        case "find_files":
            if bool("in_contents") {
                let folder = str("folder").isEmpty ? NSHomeDirectory() : (str("folder") as NSString).expandingTildeInPath
                let out = await Run.capture("/usr/bin/mdfind", ["-onlyin", folder, str("query")], timeout: 15)
                let lib = NSHomeDirectory() + "/Library/"
                let hits = out.split(separator: "\n").map(String.init).filter { !$0.hasPrefix(lib) && !$0.contains("/.") }.prefix(30)
                return ToolResult(hits.isEmpty ? "Nothing contains \u{201C}\(str("query"))\u{201D}." : hits.joined(separator: "\n"))
            }
            return ToolResult(await Files.find(str("query"), kind: str("kind")))
        case "dev":
            return ToolResult(await Dev.perform(str("action"), path: str("path"), message: str("message"), confirm: { q in await ask(q) }))
        case "http_request":
            let method = str("method").isEmpty ? "GET" : str("method").uppercased()
            if method != "GET" || tainted, !(await ask("Send \(method) to \(str("url"))?\n\n\(str("body").prefix(300))")) { return ToolResult("The user declined.") }
            var headers: [String: String] = [:]
            for line in str("headers").split(separator: "\n") {
                let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if parts.count == 2 { headers[parts[0]] = parts[1] }
            }
            return ToolResult(await HTTP.request(method: method, url: str("url"), headers: headers, body: str("body")))
        case "sqlite":
            return ToolResult(await SQLite.query(str("path"), str("query"), confirm: { q in await ask(q) }))
        case "save_document":
            let r = Documents.save(name: str("name"), format: str("format"), content: str("content"))
            if r.hasPrefix("Saved ") {
                let path = (String(r.dropFirst(6)) as NSString).expandingTildeInPath
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
            }
            return ToolResult(r)
        case "mail_draft":
            return ToolResult(await Documents.mailDraft(to: str("to"), subject: str("subject"), body: str("body"), attachment: str("attachment")))
        case "read_feed":
            return ToolResult(await Feeds.read(str("url")))
        case "spotify":
            return ToolResult(await Spotify.perform(str("action"), value: str("value")))
        case "audio":
            switch str("action") {
            case "use_output": return ToolResult(AudioDevices.use(str("name"), input: false))
            case "use_input": return ToolResult(AudioDevices.use(str("name"), input: true))
            case "noise":
                let v = (a["volume"] as? Double) ?? (a["volume"] as? Int).map(Double.init) ?? 0.3
                let type = str("type")
                return ToolResult(await MainActor.run { Ambient.shared.start(type, volume: Float(v)) })
            case "stop_noise": return ToolResult(await MainActor.run { Ambient.shared.stop() })
            default: return ToolResult(AudioDevices.describe())
            }
        case "open_file":
            let path = (str("path") as NSString).expandingTildeInPath
            guard path.hasPrefix(NSHomeDirectory() + "/"), FileManager.default.fileExists(atPath: path) else { return ToolResult("That file isn't in your home folder or doesn't exist.") }
            if tainted, !bool("reveal"), !(await ask("Open \((path as NSString).lastPathComponent)?")) { return ToolResult("The user declined.") }
            let reveal = bool("reveal")
            await MainActor.run {
                let u = URL(fileURLWithPath: path)
                if reveal { NSWorkspace.shared.activateFileViewerSelecting([u]) } else { NSWorkspace.shared.open(u) }
            }
            return ToolResult(reveal ? "Shown in Finder." : "Opened.", screenshot: true)
        case "mac_status":
            let snap = SystemMonitor.shared.snapshot()
            let focus = str("focus").lowercased()
            let top = ["all", "", "processes", "cpu", "memory"].contains(focus) ? await SystemMonitor.shared.topProcesses() : nil
            return ToolResult(SystemMonitor.report(snap, top: top, focus: focus))
        case "today_brief":
            return ToolResult(await brief())
        case "update_setting":
            guard let setSetting else { return ToolResult("Settings can't be changed from here.") }
            return ToolResult(await setSetting(str("name"), str("value")))
        case "web_search":
            guard let search else { return ToolResult("Web search needs a Gemini key.") }
            return ToolResult(await search(str("query")))
        case "fetch_url":
            return ToolResult(await Web.fetch(str("url")))
        case "disk":
            return await disk(a)
        case "organize_folder":
            return await organize(a)
        case "calendar":
            switch str("action") {
            case "create":
                guard let start = Agenda.parse(str("start")) else { return ToolResult("Missing or unreadable start time; use yyyy-MM-dd HH:mm.") }
                if tainted, !(await ask("Add \u{201C}\(str("title"))\u{201D} to your calendar?")) { return ToolResult("The user declined.") }
                return ToolResult(await Agenda.createEvent(title: str("title"), start: start, end: Agenda.parse(str("end")), location: str("location"), notes: str("notes")))
            case "delete":
                guard await ask("Delete this calendar event?\n\(str("title"))") else { return ToolResult("The user declined.") }
                return ToolResult(await Agenda.deleteEvent(id: str("id")))
            default:
                let from = Agenda.parse(str("from")).map { Calendar.current.startOfDay(for: $0) } ?? Calendar.current.startOfDay(for: Date())
                return ToolResult(await Agenda.events(days: int("days") ?? 1, from: from))
            }
        case "reminders":
            switch str("action") {
            case "create": return ToolResult(await Agenda.addReminder(title: str("title"), due: Agenda.parse(str("due")), list: str("list"), notes: str("notes")))
            case "complete": return ToolResult(await Agenda.completeReminder(id: str("id")))
            default: return ToolResult(await Agenda.reminders())
            }
        case "contacts_search":
            return ToolResult(await People.search(str("query")))
        case "notes":
            if str("action") == "create" {
                return ToolResult(await AppleApps.createNote(title: str("title").isEmpty ? "Jarvis note" : str("title"), body: str("body")))
            }
            return ToolResult(await AppleApps.searchNotes(str("query")))
        case "send_message":
            guard await ask("Send this iMessage to \(str("to"))?\n\n\(str("text").prefix(400))") else {
                return ToolResult("The user declined, so nothing was sent.")
            }
            return ToolResult(await AppleApps.sendMessage(to: str("to"), text: str("text")))
        case "mac_control":
            let action = str("action")
            if action == "wifi_off", !(await ask("Turn Wi-Fi off? Jarvis will be offline until it's back on.")) { return ToolResult("The user declined.") }
            return ToolResult(await MacControl.perform(action, value: str("value")))
        case "shortcuts":
            if str("action") == "run" {
                if tainted, !(await ask("Run the \u{201C}\(str("name"))\u{201D} shortcut?")) { return ToolResult("The user declined.") }
                return ToolResult(await Shortcuts.run(str("name"), input: str("input")))
            }
            return ToolResult(await Shortcuts.list())
        case "shell":
            guard settings.shellEnabled else { return ToolResult("Shell is turned off.") }
            return ToolResult(await Sandbox.run(str("command")))
        case "mail_unread":
            guard settings.mailEnabled else { return ToolResult("Mail is turned off.") }
            return ToolResult(await Mail.unread(limit: min(max(int("limit") ?? 5, 1), 15)))
        case "mail_send":
            guard settings.mailEnabled else { return ToolResult("Mail is turned off.") }
            guard await ask("Send email to \(str("to"))?\nSubject: \(str("subject"))\n\n\(str("body").prefix(400))") else {
                return ToolResult("The user declined, so nothing was sent.")
            }
            return ToolResult(await Mail.send(to: str("to"), subject: str("subject"), body: str("body")))
        default:
            guard let t = mcpTool(name) else { return ToolResult("Unknown tool.") }
            let trusted = settings.mcpServers.first { $0.id == t.server }?.trusted ?? false
            if !trusted || tainted, !(await ask("Let the \(t.server) tool server run \(t.name)?")) {
                return ToolResult("The user declined.")
            }
            return ToolResult(await MCPHub.shared.call(t, a))
        }
    }

    private func disk(_ a: [String: Any]) async -> ToolResult {
        func str(_ k: String) -> String { a[k] as? String ?? "" }
        func int(_ k: String) -> Int? { (a[k] as? Int) ?? (a[k] as? Double).map(Int.init) ?? (a[k] as? String).flatMap { Int($0) } }
        switch str("action") {
        case "large_files":
            let found = await DiskCare.largeFiles(minMB: max(50, int("min_mb") ?? 500))
            guard !found.isEmpty else { return ToolResult("No files that large in your home folder.") }
            return ToolResult(found.map { f in
                "\(SystemMonitor.bytes(f.size))  \(f.path)" + (f.lastUsed.map { "  (last used \($0.formatted(date: .abbreviated, time: .omitted)))" } ?? "")
            }.joined(separator: "\n"))
        case "old_downloads":
            let old = DiskCare.oldDownloads(days: int("days") ?? 60)
            guard !old.isEmpty else { return ToolResult("Nothing in Downloads is that old.") }
            let total = old.reduce(0) { $0 + $1.size }
            return ToolResult("\(old.count) items, \(SystemMonitor.bytes(total)):\n" + old.sorted { $0.size > $1.size }.prefix(30)
                .map { "\(SystemMonitor.bytes($0.size))  \($0.path)" }.joined(separator: "\n"))
        case "duplicates":
            let folder = Organizer.allowed(str("folder").isEmpty ? "~/Downloads" : str("folder"))
            guard let folder else { return ToolResult("That folder can't be scanned.") }
            let groups = DiskCare.duplicates(in: folder)
            guard !groups.isEmpty else { return ToolResult("No duplicate files found.") }
            let wasted = groups.reduce(Int64(0)) { $0 + ($1.first?.size ?? 0) * Int64($1.count - 1) }
            return ToolResult("\(groups.count) sets of duplicates, \(SystemMonitor.bytes(wasted)) could be freed. Keep one of each:\n" +
                groups.prefix(20).map { g in g.map { "  \($0.path)" }.joined(separator: "\n") + "  (\(SystemMonitor.bytes(g.first?.size ?? 0)) each)" }
                .joined(separator: "\n---\n"))
        case "clean":
            let target = str("target")
            guard DiskCare.cleanTargets.contains(target) else { return ToolResult("Unknown target. Use one of: \(DiskCare.cleanTargets.joined(separator: ", ")).") }
            guard await confirm(await DiskCare.describe(target, days: int("days") ?? 60)) else { return ToolResult("The user declined, so nothing was removed.") }
            return ToolResult(await DiskCare.clean(target, days: int("days") ?? 60))
        case "trash":
            let paths = str("paths").split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            let ok = paths.filter { DiskCare.canTrash($0) }
            guard !ok.isEmpty else { return ToolResult("None of those files can be moved: only your own files outside Library are allowed.") }
            let list = ok.prefix(12).map { "• " + ($0 as NSString).lastPathComponent }.joined(separator: "\n") + (ok.count > 12 ? "\n…and \(ok.count - 12) more" : "")
            guard await confirm("Move \(ok.count) item\(ok.count == 1 ? "" : "s") to the Trash?\n\n\(list)") else { return ToolResult("The user declined, so nothing was moved.") }
            let r = await DiskCare.trash(ok)
            var msg = "Moved \(r.moved) item\(r.moved == 1 ? "" : "s") (\(SystemMonitor.bytes(r.bytes))) to the Trash. Empty the Trash to free the space."
            if !r.skipped.isEmpty { msg += " Skipped \(r.skipped.count)." }
            return ToolResult(msg)
        default:
            return ToolResult(await DiskCare.report())
        }
    }

    private func organize(_ a: [String: Any]) async -> ToolResult {
        let action = a["action"] as? String ?? "preview"
        if action == "undo" {
            let n = Organizer.undo()
            return ToolResult(n == 0 ? "There's nothing to undo." : "Put \(n) items back where they were.")
        }
        let raw = (a["folder"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "~/Downloads"
        guard let folder = Organizer.allowed(raw) else { return ToolResult("That folder can't be organised. Use a folder in your home folder, outside Library.") }
        let plan = Organizer.plan(folder)
        guard action == "apply" else { return ToolResult(plan.summary) }
        guard !plan.moves.isEmpty else { return ToolResult(plan.summary) }
        guard await confirm(plan.summary + "\n\nYou can undo this afterwards.") else { return ToolResult("The user declined, so nothing moved.") }
        let n = Organizer.apply(plan)
        return ToolResult("Sorted \(n) items into folders. Say \u{201C}undo\u{201D} to put them back.")
    }

    private func brief() async -> String {
        var parts: [String] = []
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM, HH:mm"
        parts.append("Now: \(f.string(from: Date())).")
        if settings.calendarEnabled, Agenda.status(.event) == true {
            parts.append("Calendar today:\n" + (await Agenda.events(days: 1)))
        }
        if settings.calendarEnabled, Agenda.status(.reminder) == true {
            parts.append("Open reminders:\n" + (await Agenda.reminders()))
        }
        let snap = SystemMonitor.shared.snapshot()
        parts.append("Mac: " + SystemMonitor.spokenSummary(snap))
        if !memory.automations.isEmpty {
            parts.append("Automations: " + memory.automations.map { "\($0.label) \($0.prompt)" }.joined(separator: "; "))
        }
        return parts.joined(separator: "\n\n")
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
        if settings.confirmRisky || tainted, risk != "none", !(await confirm("\(intent) (\(risk))")) {
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
