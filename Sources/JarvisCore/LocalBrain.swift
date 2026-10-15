import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Answers small requests on this Mac so they cost nothing and come back fast.
/// Uses Apple's on-device model when Apple Intelligence is on, or a model served by Ollama.
/// The model hands anything it shouldn't answer itself back to Gemini with an ESCALATE word.
/// Reports a download's progress from 0 to 1.
final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { report(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}

public final class LocalBrain: @unchecked Sendable {
    public static let shared = LocalBrain()

    public enum Engine: String, Sendable { case apple, ollama }

    public enum Verdict: Sendable {
        case answer(String)
        case escalate(Mode)
    }

    public static let instructions = """
    You are Jarvis, a fast voice assistant on the user's Mac. Answer in one to three short spoken sentences, plain text, no markdown, no greetings.
    If the request needs any of the following, reply with exactly one word and nothing else:
    ESCALATE_WEB for news, weather, prices, scores, people in the news, or anything that may have changed recently;
    ESCALATE_SCREEN for opening apps, clicking, typing, or anything on the user's screen;
    ESCALATE_TOOLS for email, files, folders, reminders, timers, schedules, the clipboard, or remembering something;
    ESCALATE_HARD for long writing, code, maths, or careful multi-step reasoning.
    If you are not certain a fact is correct, reply ESCALATE_WEB.
    When live data about this Mac is included, answer questions about the Mac from it directly.
    Use what you know about the user and the conversation so far; a short follow-up continues the previous topic.
    """

    private let lock = NSLock()
    private var cachedOllama: (at: Date, models: [String]) = (.distantPast, [])
    private var lastOllamaWarm = Date.distantPast
    private var prepared: AnyObject?

    // MARK: Availability

    public func appleStatus() -> (ready: Bool, detail: String) {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability {
                return (true, "Apple on-device model is ready.")
            }
            return (false, "Apple's on-device model isn't available. Turn on Apple Intelligence in System Settings.")
        }
        #endif
        return (false, "Apple's on-device model needs macOS 26 with Apple Intelligence.")
    }

    public func ollamaModels(fresh: Bool = false) async -> [String] {
        let cached = lock.withLock { cachedOllama }
        if !fresh, Date().timeIntervalSince(cached.at) < 30 { return cached.models }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/tags")!)
        req.timeoutInterval = 1.5
        var models: [String] = []
        if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            models = (obj["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        }
        lock.withLock { cachedOllama = (Date(), models) }
        return models
    }

    /// Capable but quick models first; they reply in well under a second once loaded.
    public static func pickSmall(_ models: [String]) -> String? {
        let usable = models.filter { !$0.contains("embed") }
        let order = ["qwen3:8b", "qwen3:4b", "gemma3:4b", "llama3.2:3b", "phi4-mini", "qwen2.5:7b", "qwen2.5:3b", "llama3.1:8b",
                     "qwen3", "gemma3", "llama3.2", "phi", "mistral"]
        for p in order { if let m = usable.first(where: { $0.hasPrefix(p) }) { return m } }
        return usable.first
    }

    /// Models worth suggesting, with their approximate download size.
    public static let suggested: [(name: String, label: String, size: String)] = [
        ("qwen3:8b", "Smart: best answers, still quick on Apple silicon", "5.2 GB"),
        ("qwen3:4b", "Fast: lighter, replies almost instantly", "2.6 GB"),
        ("llama3.2:3b", "Fastest: smallest download", "2.0 GB"),
    ]

    public func resolve(_ s: JarvisSettings) async -> (Engine, String)? {
        func ollama() async -> (Engine, String)? {
            let list = await ollamaModels()
            if !s.ollamaModel.isEmpty, list.contains(s.ollamaModel) { return (.ollama, s.ollamaModel) }
            return Self.pickSmall(list).map { (.ollama, $0) }
        }
        switch s.localEngine {
        case "off": return nil
        case "apple": return appleStatus().ready ? (.apple, "apple-on-device") : nil
        case "ollama": return await ollama()
        default:
            // Ollama runs larger, smarter models, so it wins whenever it's installed and running.
            if let o = await ollama() { return o }
            return appleStatus().ready ? (.apple, "apple-on-device") : nil
        }
    }

    // MARK: Ollama setup

    public static var ollamaInstalled: Bool {
        ["/Applications/Ollama.app", "/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// Installs the official Ollama app (native to Apple silicon) into /Applications, after checking it's
    /// signed and notarised by Ollama. Homebrew isn't used: an Intel Homebrew would build a slow Rosetta copy.
    /// Ollama's Apple Developer team (its company is Infra Technologies, Inc).
    static let ollamaTeam = "3MU9H2V9Y9"

    public func installOllamaApp(progress: @escaping @Sendable (Double) -> Void) async throws {
        let source = URL(string: "https://ollama.com/download/Ollama-darwin.zip")!
        let reporter = DownloadProgress(progress)
        let (tmp, resp) = try await URLSession.shared.download(from: source, delegate: reporter)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.other("Ollama's download didn't start. Try again in a moment.") }
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-ollama-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        _ = await Run.capture("/usr/bin/ditto", ["-x", "-k", tmp.path, staging.path], timeout: 300)
        let app = staging.appendingPathComponent("Ollama.app")
        guard FileManager.default.fileExists(atPath: app.path) else { throw LLMError.other("The Ollama download was incomplete.") }
        // Only keep it if it's genuinely Ollama's, signed with their Developer ID and notarised by Apple.
        let sig = await Run.capture("/usr/bin/codesign", ["-dv", "--verbose=2", app.path])
        let gate = await Run.capture("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path])
        guard sig.contains("TeamIdentifier=\(Self.ollamaTeam)"), gate.contains("accepted"), gate.contains("Notarized Developer ID") else {
            throw LLMError.other("The downloaded Ollama app didn't pass the signature check, so it wasn't installed.")
        }
        let dest = URL(fileURLWithPath: "/Applications/Ollama.app")
        if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
        try FileManager.default.moveItem(at: app, to: dest)
    }

    /// Starts Ollama in the background if it's installed but not running.
    public func startOllama() async -> Bool {
        if await ollamaReachable() { return true }
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            _ = await Run.capture("/usr/bin/open", ["-g", "-a", "Ollama"])
        } else if let bin = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"].first(where: { FileManager.default.fileExists(atPath: $0) }) {
            _ = await Run.capture("/bin/sh", ["-c", "nohup '\(bin)' serve >/dev/null 2>&1 &"])
        } else {
            return false
        }
        for _ in 0..<20 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if await ollamaReachable() { return true }
        }
        return false
    }

    public func ollamaReachable() async -> Bool {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/version")!)
        req.timeoutInterval = 1
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    /// Downloads a model through Ollama, reporting progress from 0 to 1.
    public func pull(_ model: String, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/pull")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.timeoutInterval = 3600
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.other("Ollama couldn't start the download.") }
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw LLMError.other(err) }
            let status = obj["status"] as? String ?? ""
            let total = (obj["total"] as? NSNumber)?.doubleValue ?? 0
            let done = (obj["completed"] as? NSNumber)?.doubleValue ?? 0
            progress(total > 0 ? done / total : (status == "success" ? 1 : 0), status)
        }
        lock.withLock { cachedOllama = (.distantPast, []) }
    }

    // MARK: Speed

    /// Called the moment the user starts speaking, so the model is loaded before they finish.
    public func prewarm(_ s: JarvisSettings) {
        Task {
            guard let (engine, model) = await resolve(s) else { return }
            switch engine {
            case .apple:
                #if canImport(FoundationModels)
                if #available(macOS 26.0, *) {
                    let session = LanguageModelSession(instructions: Self.instructions)
                    session.prewarm()
                    lock.withLock { prepared = session }
                }
                #endif
            case .ollama:
                let due = lock.withLock { () -> Bool in
                    guard Date().timeIntervalSince(lastOllamaWarm) > 240 else { return false }
                    lastOllamaWarm = Date()
                    return true
                }
                guard due else { return }
                var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/generate")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "content-type")
                req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "10m"])
                _ = try? await URLSession.shared.data(for: req)
            }
        }
    }

    // MARK: Answering

    /// Streams the growing answer text. Returns nil when no local model is available.
    public func stream(_ prompt: String, history: [(role: String, text: String)], settings s: JarvisSettings,
                       context: String? = nil) async -> (AsyncThrowingStream<String, Error>, Engine)? {
        guard let (engine, model) = await resolve(s) else { return nil }
        let live = context.map { "\($0)\n\n" } ?? ""
        switch engine {
        case .apple:
            #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                var text = live
                for h in history.suffix(10) { text += (h.role == "user" ? "User: " : "Jarvis: ") + h.text + "\n" }
                text += text.isEmpty ? prompt : "User: \(prompt)"
                return (appleStream(text), .apple)
            }
            #endif
            return nil
        case .ollama:
            var messages: [[String: String]] = [["role": "system", "content": Self.instructions + (live.isEmpty ? "" : "\n\n" + live)]]
            for h in history.suffix(10) { messages.append(["role": h.role == "user" ? "user" : "assistant", "content": h.text]) }
            messages.append(["role": "user", "content": prompt])
            return (ollamaStream(model: model, messages: messages), .ollama)
        }
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func appleStream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        let session = lock.withLock { () -> LanguageModelSession in
            let s = (prepared as? LanguageModelSession) ?? LanguageModelSession(instructions: Self.instructions)
            prepared = nil
            return s
        }
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await snap in session.streamResponse(to: prompt) { cont.yield(snap.content) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
    #endif

    private func ollamaStream(model: String, messages: [[String: String]]) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    var req = URLRequest(url: URL(string: "http://127.0.0.1:11434/api/chat")!)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "content-type")
                    req.timeoutInterval = 60
                    var body: [String: Any] = [
                        "model": model, "messages": messages, "stream": true, "keep_alive": "15m",
                        "options": ["num_predict": 400, "temperature": 0.5],
                    ]
                    // Reasoning models think out loud first; for a voice assistant that's just delay.
                    if ["qwen3", "deepseek-r1", "magistral"].contains(where: { model.hasPrefix($0) }) { body["think"] = false }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw LLMError.other("Ollama didn't accept the request.") }
                    var text = ""
                    for try await line in bytes.lines {
                        guard let d = line.data(using: .utf8),
                              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                        if let m = obj["message"] as? [String: Any], let c = m["content"] as? String {
                            text += c
                            cont.yield(Self.stripThinking(text))
                        }
                        if obj["done"] as? Bool == true { break }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    /// Reasoning models wrap their thoughts in <think> tags; only the answer is spoken.
    static func stripThinking(_ s: String) -> String {
        var out = s
        while let open = out.range(of: "<think>") {
            if let close = out.range(of: "</think>", range: open.upperBound..<out.endIndex) {
                out.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                out.removeSubrange(open.lowerBound..<out.endIndex)
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decides early whether the stream is an answer or a hand-off. nil means "not sure yet".
    public static func verdict(_ text: String, finished: Bool) -> Verdict? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = t.uppercased()
        if upper.hasPrefix("ESCALATE") || (!finished && "ESCALATE".hasPrefix(upper) && !upper.isEmpty) {
            guard finished || upper.count >= 12 else { return nil }
            if upper.contains("WEB") { return .escalate(.web) }
            if upper.contains("SCREEN") { return .escalate(.screen) }
            if upper.contains("HARD") { return .escalate(.hard) }
            if upper.contains("TOOL") { return .escalate(.chat) }
            return finished ? .escalate(.chat) : nil
        }
        if t.isEmpty { return finished ? .escalate(.chat) : nil }
        return .answer(t)
    }
}
