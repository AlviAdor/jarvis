import Foundation
import AppKit
import ApplicationServices

/// Using other AI assistants the way a person does: open the app or site, type the prompt into its
/// message box where you can see it, send it, and optionally read the reply back.
public enum AIApps {
    public struct Target: Sendable, Equatable {
        public let id: String
        public let name: String
        public let bundle: String?       // desktop app, used when installed
        public let web: String           // otherwise the website
        public let prefill: String?      // a URL that fills the box, as a last resort
    }

    public static let targets: [Target] = [
        Target(id: "chatgpt", name: "ChatGPT", bundle: "com.openai.chat", web: "https://chatgpt.com/", prefill: "https://chatgpt.com/?q="),
        Target(id: "claude", name: "Claude", bundle: "com.anthropic.claudefordesktop", web: "https://claude.ai/new", prefill: "https://claude.ai/new?q="),
        Target(id: "gemini", name: "Gemini", bundle: nil, web: "https://gemini.google.com/app", prefill: nil),
        Target(id: "grok", name: "Grok", bundle: "ai.x.grok", web: "https://grok.com/", prefill: "https://grok.com/?q="),
        Target(id: "perplexity", name: "Perplexity", bundle: "ai.perplexity.mac", web: "https://www.perplexity.ai/", prefill: "https://www.perplexity.ai/search?q="),
        Target(id: "copilot", name: "Copilot", bundle: "com.microsoft.copilot-mac", web: "https://copilot.microsoft.com/", prefill: nil),
    ]

    static let aliases: [String: String] = [
        "chatgpt": "chatgpt", "chat gpt": "chatgpt", "gpt": "chatgpt", "openai": "chatgpt",
        "claude": "claude", "clod": "claude", "cloud ai": "claude",
        "gemini": "gemini", "bard": "gemini",
        "grok": "grok", "grock": "grok", "groc": "grok",
        "perplexity": "perplexity", "copilot": "copilot", "co-pilot": "copilot",
    ]

    public static func target(_ name: String) -> Target? {
        let key = aliases[name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)] ?? name.lowercased()
        return targets.first { $0.id == key }
    }

    /// "Ask ChatGPT to plan my week" → (chatgpt, "plan my week"). Nil when the request isn't for another AI.
    public static func request(in text: String) -> (target: Target, ask: String)? {
        let lower = text.lowercased()
        let names = aliases.keys.sorted { $0.count > $1.count }.joined(separator: "|").replacingOccurrences(of: " ", with: "\\s+")
        let verbs = "ask|tell|prompt|message|have|get|use|type (?:this |it )?(?:in|into)|put (?:this |it )?(?:in|into)|send (?:this |it )?to|open"
        // Only connecting words are dropped ("and ask it to", "to", "about", ":"); the request itself is kept whole.
        let pattern = "^(?:hey |ok |jarvis,? )?(?:can you |please |could you )?(?:\(verbs))\\s+(\(names))\\b(?:\\s+and\\s+(?:ask|tell)\\s+(?:it\\s+)?(?:to\\s+)?|\\s+to\\s+|\\s+about\\s+|\\s+for\\s+|\\s*[:,]\\s*|\\s+)(.*)$"
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
              let nameRange = Range(m.range(at: 1), in: lower), let askRange = Range(m.range(at: 2), in: text) else { return nil }
        let name = String(lower[nameRange]).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        guard let t = target(name) else { return nil }
        let ask = String(text[askRange]).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.")))
        return ask.count >= 3 ? (t, ask) : nil
    }

    /// Instructions for turning spoken words into a good prompt.
    public static let promptInstructions = """
    Rewrite the user's spoken request as a clear, well-structured prompt for an AI assistant.
    Keep every detail and the user's intent; don't invent facts about them. Where it helps, state the goal, the relevant context,
    any constraints, and the format of the answer wanted. Write it as the user, in the first person, in the language they used.
    Output only the prompt itself, with no preamble or quotes.
    """

    // MARK: Driving the app

    static func installedApp(_ t: Target) -> URL? {
        t.bundle.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Opens the assistant and brings it to the front. Returns whether it's the desktop app.
    @MainActor
    static func open(_ t: Target) async -> Bool {
        if let app = installedApp(t) {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: cfg)
            return true
        }
        if let u = URL(string: t.web) { NSWorkspace.shared.open(u) }
        return false
    }

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String) ?? ""
    }

    /// The front app's message box: the text area or field nearest the bottom of the window, preferring one
    /// whose placeholder reads like a chat prompt.
    static func messageBox() -> AXUIElement? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return nil }
        let root = AXUIElementCreateApplication(front.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.8)
        guard let w = attr(root, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return nil }
        var fields: [(AXUIElement, CGFloat, Bool)] = []
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 40, visited < 6000 else { return }
            visited += 1
            let role = str(el, kAXRoleAttribute)
            if role == "AXTextArea" || role == "AXTextField" || (role == "AXGroup" && str(el, "AXDOMClassList").contains("ProseMirror")) {
                let hint = (str(el, "AXPlaceholderValue") + " " + str(el, kAXDescriptionAttribute) + " " + str(el, kAXTitleAttribute)).lowercased()
                let chatty = ["message", "ask", "reply", "prompt", "help", "anything", "chat", "send", "question", "type"].contains { hint.contains($0) }
                let y = UIControl.frame(el)?.maxY ?? 0
                if str(el, kAXSubroleAttribute) != "AXSecureTextField", !hint.contains("search") || chatty { fields.append((el, y, chatty)) }
            }
            for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(w, depth: 0)
        return fields.sorted { ($0.2 ? 1 : 0, $0.1) > ($1.2 ? 1 : 0, $1.1) }.first?.0
    }

    /// Types the prompt where the user can watch it; new lines become Shift-Return so nothing is sent early.
    static func typeVisibly(_ text: String) async {
        let lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if KillSwitch.shared.tripped { return }
            await Input.type(line)
            if i < lines.count - 1 { _ = await Input.key("shift+return") }
        }
    }

    /// Opens the assistant, puts the prompt in its message box, and sends it.
    public static func send(_ t: Target, prompt: String, submit: Bool = true) async -> String {
        guard AXIsProcessTrusted() else { return "Couldn't type into \(t.name): Accessibility permission is off." }
        let desktop = await open(t)
        // Give the app or page time to come up, then look for the message box.
        var box: AXUIElement?
        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if KillSwitch.shared.tripped { return "Stopped." }
            box = messageBox()
            if box != nil { break }
        }
        if let box {
            AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
            if let f = UIControl.frame(box) { await Input.click(at: CGPoint(x: f.midX, y: f.midY)) }
            await typeVisibly(prompt)
        } else if !desktop, let pre = t.prefill, let q = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let u = URL(string: pre + q) {
            // The page didn't expose its box; this address opens it with the prompt already in place.
            await MainActor.run { _ = NSWorkspace.shared.open(u) }
            return "Opened \(t.name) with your prompt (it fills in from the address)."
        } else {
            return "Opened \(t.name), but couldn't find its message box. Click into it and I'll type, or use the screen."
        }
        if submit {
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = await Input.key("return")
            return "Typed your prompt into \(t.name) and sent it."
        }
        return "Typed your prompt into \(t.name). It's ready to send."
    }

    /// Waits for the assistant's reply to settle, then returns the text that came after the prompt.
    public static func readReply(after prompt: String, timeout: TimeInterval = 90) async -> String {
        func windowText() -> String {
            guard let front = NSWorkspace.shared.frontmostApplication else { return "" }
            let root = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(root, 0.8)
            guard let w = attr(root, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return "" }
            var parts: [String] = []
            var visited = 0
            func walk(_ el: AXUIElement, depth: Int) {
                guard depth < 45, visited < 9000 else { return }
                visited += 1
                if str(el, kAXRoleAttribute) == "AXStaticText" {
                    let v = str(el, kAXValueAttribute)
                    if !v.isEmpty { parts.append(v) }
                }
                for c in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(c, depth: depth + 1) }
            }
            walk(w, depth: 0)
            return parts.joined(separator: " ")
        }
        let start = Date()
        var last = ""
        var stableSince = Date()
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        while Date().timeIntervalSince(start) < timeout {
            if KillSwitch.shared.tripped { break }
            let now = windowText()
            if now != last { last = now; stableSince = Date() }
            else if Date().timeIntervalSince(stableSince) > 4, !now.isEmpty { break }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        let key = String(prompt.prefix(60))
        let reply = last.range(of: key, options: .backwards).map { String(last[$0.upperBound...]) } ?? String(last.suffix(3000))
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "I couldn't read the reply from the window." : String(trimmed.prefix(4000))
    }
}
