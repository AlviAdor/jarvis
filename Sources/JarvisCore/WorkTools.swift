import Foundation
import AppKit
import AVFoundation
import CoreAudio

/// Git, GitHub pull requests, tests, formatting and linting for projects in the home folder.
public enum Dev {
    /// The repository containing `path` (it or a parent has a .git folder), inside the home folder.
    public static func repo(_ path: String) -> URL? {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard url.path.hasPrefix(NSHomeDirectory() + "/") else { return nil }
        while url.path.count > NSHomeDirectory().count {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func git(_ args: [String], in repo: URL, timeout: TimeInterval = 60) async -> String {
        await Run.capture("/usr/bin/git", ["-C", repo.path] + args, timeout: timeout)
    }

    /// What `run_tests`, `format` and `lint` will run for this kind of project, if anything.
    public static func command(_ kind: String, in repo: URL) -> [String]? {
        func has(_ f: String) -> Bool { FileManager.default.fileExists(atPath: repo.appendingPathComponent(f).path) }
        switch kind {
        case "test":
            if has("Package.swift") { return ["swift", "test"] }
            if has("package.json") { return ["npm", "test", "--silent"] }
            if has("Cargo.toml") { return ["cargo", "test"] }
            if has("go.mod") { return ["go", "test", "./..."] }
            if has("pyproject.toml") || has("pytest.ini") || has("setup.py") || has("tests") { return ["python3", "-m", "pytest", "-q"] }
            if has("Makefile") { return ["make", "test"] }
        case "format":
            if has("package.json") { return ["npx", "--yes", "prettier", "--write", "."] }
            if has("pyproject.toml") || has("setup.py") { return ["python3", "-m", "black", "."] }
            if has("Package.swift") { return ["swift", "format", "--in-place", "--recursive", "Sources"] }
            if has("Cargo.toml") { return ["cargo", "fmt"] }
            if has("go.mod") { return ["gofmt", "-w", "."] }
        case "lint":
            if has("package.json") { return ["npx", "--yes", "eslint", "."] }
            if has("pyproject.toml") || has("setup.py") { return ["python3", "-m", "ruff", "check", "."] }
            if has("Cargo.toml") { return ["cargo", "clippy", "--quiet"] }
            if has("go.mod") { return ["go", "vet", "./..."] }
            if has("Package.swift") { return ["swift", "build"] }
        default: break
        }
        return nil
    }

    static func run(_ cmd: [String], in repo: URL, timeout: TimeInterval = 600) async -> String {
        let out = await Run.capture("/bin/sh", ["-c", "cd \"$0\" && exec \"$@\"", repo.path] + cmd, timeout: timeout)
        return out.count > 6000 ? "…" + out.suffix(6000) : (out.isEmpty ? "(finished with no output)" : out)
    }

    public static func perform(_ action: String, path: String, message: String, confirm: (String) async -> Bool) async -> String {
        guard let repo = repo(path.isEmpty ? FileManager.default.currentDirectoryPath : path) else {
            return "That isn't a git project in your home folder. Give the project's folder path."
        }
        switch action {
        case "status": return await git(["status", "--short", "--branch"], in: repo)
        case "log": return await git(["log", "--oneline", "--decorate", "-n", "15"], in: repo)
        case "branches": return await git(["branch", "-a", "-vv"], in: repo)
        case "diff":
            let stat = await git(["diff", "HEAD", "--stat"], in: repo)
            let full = await git(["diff", "HEAD"], in: repo)
            return stat + "\n\n" + String(full.prefix(8000))
        case "commit":
            guard !message.isEmpty else { return "Write a commit message first (look at the diff to draft one)." }
            let stat = await git(["status", "--short"], in: repo)
            guard !stat.isEmpty else { return "There's nothing to commit." }
            guard await confirm("Commit all changes in \(repo.lastPathComponent)?\n\n\(message)\n\n\(stat.prefix(400))") else { return "The user declined." }
            _ = await git(["add", "-A"], in: repo)
            return await git(["commit", "-q", "-m", message], in: repo) + "\n" + (await git(["log", "--oneline", "-1"], in: repo))
        case "push":
            guard await confirm("Push \(repo.lastPathComponent) to its remote?") else { return "The user declined." }
            _ = await git(["pull", "--rebase", "-q"], in: repo, timeout: 120)
            let out = await git(["push"], in: repo, timeout: 120)
            return out.isEmpty ? "Pushed." : out
        case "pr_status":
            return await Run.capture("/usr/bin/env", ["sh", "-c", "cd \"$0\" && gh pr status 2>&1 || echo 'GitHub CLI (gh) is not set up.'", repo.path], timeout: 30)
        case "test", "format", "lint":
            guard let cmd = command(action, in: repo) else { return "I don't know how to \(action) this kind of project." }
            guard await confirm("Run \(cmd.joined(separator: " ")) in \(repo.lastPathComponent)?") else { return "The user declined." }
            return "$ \(cmd.joined(separator: " "))\n" + (await run(cmd, in: repo))
        default:
            return "Developer actions: status, log, branches, diff, commit, push, pr_status, test, format, lint."
        }
    }
}

/// Trying an API without opening another app.
public enum HTTP {
    public static func request(method: String, url: String, headers: [String: String], body: String) async -> String {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return "Give a full http or https URL." }
        var req = URLRequest(url: u)
        req.httpMethod = method.uppercased()
        req.timeoutInterval = 30
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if !body.isEmpty {
            req.httpBody = Data(body.utf8)
            if headers.keys.allSatisfy({ $0.lowercased() != "content-type" }), body.first == "{" || body.first == "[" {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        let start = Date()
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let h = resp as? HTTPURLResponse
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            var text = String(decoding: data.prefix(200_000), as: UTF8.self)
            if let obj = try? JSONSerialization.jsonObject(with: data),
               let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) {
                text = String(decoding: pretty, as: UTF8.self)
            }
            let type = h?.value(forHTTPHeaderField: "Content-Type") ?? ""
            return "HTTP \(h?.statusCode ?? 0) in \(ms) ms\(type.isEmpty ? "" : " · \(type)")\n\n" + String(text.prefix(6000))
        } catch {
            return "The request failed: \(error.localizedDescription)"
        }
    }
}

/// Looking into SQLite databases; changes ask first.
public enum SQLite {
    public static func isWrite(_ sql: String) -> Bool {
        let s = sql.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["insert", "update", "delete", "create", "drop", "alter", "replace", "vacuum", "attach", "pragma writable"].contains { s.hasPrefix($0) }
    }

    public static func query(_ path: String, _ sql: String, confirm: (String) async -> Bool) async -> String {
        let file = (path as NSString).expandingTildeInPath
        guard file.hasPrefix(NSHomeDirectory() + "/"), FileManager.default.fileExists(atPath: file) else { return "That database isn't in your home folder." }
        let write = isWrite(sql)
        if write, !(await confirm("Change the database \((file as NSString).lastPathComponent)?\n\n\(sql.prefix(400))")) { return "The user declined." }
        let args = (write ? [] : ["-readonly"]) + ["-header", "-column", file, sql]
        let out = await Run.capture("/usr/bin/sqlite3", args, timeout: 30)
        return out.isEmpty ? (write ? "Done." : "(no rows)") : String(out.prefix(6000))
    }
}

/// Spotify through its AppleScript support.
public enum Spotify {
    public static func perform(_ action: String, value: String) async -> String {
        let q = "\"" + AppleScript.escape(value) + "\""
        let script: String
        switch action {
        case "now_playing":
            script = """
            if application "Spotify" is not running then return "Spotify isn't open."
            tell application "Spotify"
                if player state is stopped then return "Nothing is playing."
                set t to current track
                return (name of t) & " by " & (artist of t) & " from " & (album of t) & " (" & (player state as string) & ") " & (spotify url of t)
            end tell
            """
        case "play": script = value.isEmpty ? "tell application \"Spotify\" to play" : "tell application \"Spotify\" to play track \(q)"
        case "pause": script = "tell application \"Spotify\" to pause"
        case "play_pause": script = "tell application \"Spotify\" to playpause"
        case "next": script = "tell application \"Spotify\" to next track"
        case "previous": script = "tell application \"Spotify\" to previous track"
        case "shuffle": script = "tell application \"Spotify\" to set shuffling to not shuffling\ntell application \"Spotify\" to return \"Shuffle \" & (shuffling as string)"
        case "repeat": script = "tell application \"Spotify\" to set repeating to not repeating\ntell application \"Spotify\" to return \"Repeat \" & (repeating as string)"
        case "volume": script = "tell application \"Spotify\" to set sound volume to \(max(0, min(Int(value) ?? 50, 100)))"
        case "search":
            let enc = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
            script = "open location \"spotify:search:\(enc)\"\nreturn \"Opened Spotify search for \(AppleScript.escape(value)). Use ui to press Play on a result, or play a spotify: link.\""
        default:
            return "Spotify actions: now_playing, play (optionally a spotify: link), pause, play_pause, next, previous, shuffle, repeat, volume, search."
        }
        let out = await Scripting.run(script)
        return out == "(done)" ? "Done." : out
    }
}

/// Which speakers and microphone the Mac uses.
public enum AudioDevices {
    public struct Device: Sendable, Equatable {
        public let id: AudioDeviceID
        public let name: String
        public let outputs: Int
        public let inputs: Int
    }

    static func property(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr
    }

    static func channels(_ id: AudioDeviceID, input: Bool) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    public static func all() -> [Device] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var name: Unmanaged<CFString>?
            var a = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var s = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            AudioObjectGetPropertyData(id, &a, 0, nil, &s, &name)
            return Device(id: id, name: (name?.takeRetainedValue() as String?) ?? "Device \(id)", outputs: channels(id, input: false), inputs: channels(id, input: true))
        }
    }

    static func current(_ input: Bool) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        _ = property(AudioObjectID(kAudioObjectSystemObject), input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice, &id)
        return id
    }

    public static func describe() -> String {
        let devices = all()
        let out = current(false), inp = current(true)
        let o = devices.filter { $0.outputs > 0 }.map { ($0.id == out ? "• " : "  ") + $0.name }
        let i = devices.filter { $0.inputs > 0 }.map { ($0.id == inp ? "• " : "  ") + $0.name }
        return "Outputs:\n" + o.joined(separator: "\n") + "\nInputs:\n" + i.joined(separator: "\n") + "\n(• is in use)"
    }

    public static func use(_ name: String, input: Bool) -> String {
        let want = name.lowercased()
        let candidates = all().filter { input ? $0.inputs > 0 : $0.outputs > 0 }
        guard let d = candidates.first(where: { $0.name.lowercased() == want }) ?? candidates.first(where: { $0.name.lowercased().contains(want) }) else {
            return "No \(input ? "microphone" : "output") called \(name). Available: \(candidates.map(\.name).joined(separator: ", "))"
        }
        var id = d.id
        var addr = AudioObjectPropertyAddress(mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let ok = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
        return ok ? "Now using \(d.name) for \(input ? "input" : "sound")." : "macOS didn't switch to \(d.name)."
    }
}

/// White, pink or brown noise for focus, made on the Mac: no streams, no files, nothing to license.
public final class Ambient: @unchecked Sendable {
    public static let shared = Ambient()
    private let engine = AVAudioEngine()
    private var node: AVAudioSourceNode?
    private let lock = NSLock()
    private var kind = "pink"
    private var b = [Float](repeating: 0, count: 7)
    private var brown: Float = 0
    public private(set) var playing = false

    private func sample() -> Float {
        let white = Float.random(in: -1...1)
        switch kind {
        case "white": return white * 0.25
        case "brown":
            brown = (brown + 0.02 * white) / 1.02
            return brown * 3.2
        default:   // pink, Paul Kellet's filter
            b[0] = 0.99886 * b[0] + white * 0.0555179; b[1] = 0.99332 * b[1] + white * 0.0750759
            b[2] = 0.96900 * b[2] + white * 0.1538520; b[3] = 0.86650 * b[3] + white * 0.3104856
            b[4] = 0.55000 * b[4] + white * 0.5329522; b[5] = -0.7616 * b[5] - white * 0.0168980
            let out = b[0] + b[1] + b[2] + b[3] + b[4] + b[5] + b[6] + white * 0.5362
            b[6] = white * 0.115926
            return out * 0.06
        }
    }

    public func start(_ type: String, volume: Float) -> String {
        lock.withLock { kind = ["white", "pink", "brown"].contains(type) ? type : "pink" }
        if node == nil {
            let fmt = engine.outputNode.inputFormat(forBus: 0)
            let mono = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate, channels: 1)!
            let n = AVAudioSourceNode(format: mono) { [weak self] _, _, frames, list -> OSStatus in
                guard let self else { return noErr }
                let buf = UnsafeMutableAudioBufferListPointer(list)
                self.lock.lock()
                for f in 0..<Int(frames) {
                    let v = self.sample()
                    for b in buf { b.mData?.assumingMemoryBound(to: Float.self)[f] = v }
                }
                self.lock.unlock()
                return noErr
            }
            engine.attach(n)
            engine.connect(n, to: engine.mainMixerNode, format: mono)
            node = n
        }
        engine.mainMixerNode.outputVolume = max(0.02, min(volume, 1))
        do { try engine.start() } catch { return "Couldn't start the sound: \(error.localizedDescription)" }
        playing = true
        return "Playing \(kind) noise. Say \u{201C}stop the noise\u{201D} to end it."
    }

    public func stop() -> String {
        engine.stop()
        playing = false
        return "Stopped the noise."
    }
}

/// Proposals, contracts, reports and case studies saved as real documents.
public enum Documents {
    public static var folder: URL {
        let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// A small Markdown-to-HTML renderer: headings, lists, bold, italics, code and paragraphs.
    public static func html(_ md: String) -> String {
        func inline(_ s: String) -> String {
            var t = s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<b>$1</b>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)\*"#, with: "<i>$1</i>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"`(.+?)`"#, with: "<code>$1</code>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\[(.+?)\]\((https?://[^)]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
            return t
        }
        var out: [String] = []
        var list: String?
        var code = false
        var para: [String] = []
        func flush() {
            if !para.isEmpty { out.append("<p>" + para.map(inline).joined(separator: "<br>") + "</p>"); para = [] }
        }
        func endList() { if let l = list { out.append("</\(l)>"); list = nil } }
        for raw in md.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { flush(); endList(); out.append(code ? "</pre>" : "<pre>"); code.toggle(); continue }
            if code { out.append(raw.replacingOccurrences(of: "<", with: "&lt;")); continue }
            if line.isEmpty { flush(); endList(); continue }
            if let h = line.prefix(while: { $0 == "#" }).count as Int?, h > 0, h <= 6, line.dropFirst(h).hasPrefix(" ") {
                flush(); endList(); out.append("<h\(h)>\(inline(String(line.dropFirst(h + 1))))</h\(h)>"); continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flush(); if list != "ul" { endList(); out.append("<ul>"); list = "ul" }
                out.append("<li>\(inline(String(line.dropFirst(2))))</li>"); continue
            }
            if let r = line.range(of: #"^\d+[.)] "#, options: .regularExpression) {
                flush(); if list != "ol" { endList(); out.append("<ol>"); list = "ol" }
                out.append("<li>\(inline(String(line[r.upperBound...])))</li>"); continue
            }
            endList()
            para.append(line)
        }
        flush(); endList()
        return "<html><head><meta charset=\"utf-8\"><style>body{font-family:-apple-system,Helvetica;font-size:12pt;line-height:1.45}h1{font-size:20pt}h2{font-size:15pt}pre,code{font-family:Menlo;font-size:10pt}</style></head><body>" + out.joined(separator: "\n") + "</body></html>"
    }

    public static func save(name: String, format: String, content: String) -> String {
        let f = format.lowercased()
        let base = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let ext = ["md", "txt", "rtf", "docx", "html"].contains(f) ? f : "docx"
        let url = FileOps.free(folder.appendingPathComponent((base.isEmpty ? "Document" : base) + "." + ext))
        do {
            switch ext {
            case "md", "txt": try content.write(to: url, atomically: true, encoding: .utf8)
            case "html": try html(content).write(to: url, atomically: true, encoding: .utf8)
            default:
                let attr = try NSAttributedString(data: Data(html(content).utf8),
                                                  options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                                                  documentAttributes: nil)
                let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : .officeOpenXML
                let data = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: type])
                try data.write(to: url)
            }
            return "Saved \(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
        } catch {
            return "Couldn't save it: \(error.localizedDescription)"
        }
    }

    /// A Mail draft, opened for the user to review and send.
    public static func mailDraft(to: String, subject: String, body: String, attachment: String) async -> String {
        let path = (attachment as NSString).expandingTildeInPath
        let attach = attachment.isEmpty || !FileManager.default.fileExists(atPath: path) ? "" :
            "tell content of msg to make new attachment with properties {file name:(POSIX file \"\(AppleScript.escape(path))\")} at after last paragraph"
        return await Scripting.run("""
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(AppleScript.escape(subject))", content:"\(AppleScript.escape(body))", visible:true}
            \(to.isEmpty ? "" : "tell msg to make new to recipient with properties {address:\"\(AppleScript.escape(to))\"}")
            \(attach)
            activate
        end tell
        return "Draft is open in Mail for you to check and send."
        """)
    }
}

/// RSS and Atom feeds: job boards, blogs, news.
public enum Feeds {
    final class Parser: NSObject, XMLParserDelegate {
        var items: [[String: String]] = []
        private var current: [String: String]?
        private var text = ""
        private var link = ""

        func parser(_ p: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "item" || name == "entry" { current = [:] }
            if name == "link", current != nil, let href = attributes["href"] { link = href }
            text = ""
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { text += s }
        func parser(_ p: XMLParser, foundCDATA d: Data) { text += String(decoding: d, as: UTF8.self) }
        func parser(_ p: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard var item = current else { return }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name {
            case "title": item["title"] = t
            case "link": item["link"] = t.isEmpty ? link : t
            case "pubDate", "published", "updated": if item["date"] == nil { item["date"] = t }
            case "description", "summary", "content": if item["summary"] == nil { item["summary"] = t }
            case "item", "entry":
                items.append(item)
                current = nil
                link = ""
                return
            default: break
            }
            current = item
        }
    }

    public static func read(_ url: String, limit: Int = 15) async -> String {
        guard let u = URL(string: url) else { return "That isn't a valid feed address." }
        guard let (data, _) = try? await URLSession.shared.data(from: u) else { return "Couldn't load the feed." }
        let p = Parser()
        let xml = XMLParser(data: data)
        xml.delegate = p
        xml.parse()
        guard !p.items.isEmpty else { return "No items found; that may not be an RSS or Atom feed." }
        return p.items.prefix(limit).map { i in
            let summary = Web.readable(i["summary"] ?? "").prefix(220)
            return "• \(i["title"] ?? "Untitled")\(i["date"].map { " (\($0))" } ?? "")\n  \(i["link"] ?? "")\n  \(summary)"
        }.joined(separator: "\n")
    }
}
