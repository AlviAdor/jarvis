import Foundation

/// A local tool server speaking the Model Context Protocol over stdio.
public struct MCPServerConfig: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var command: String
    public var args: [String]
    public var enabled: Bool
    public var trusted: Bool   // trusted servers run without asking each time
    /// Environment variables holding access tokens. Their values live in the Keychain, never in settings.
    public var secrets: [String]
    public var about: String

    public init(id: String, command: String, args: [String], enabled: Bool = true, trusted: Bool = false,
                secrets: [String] = [], about: String = "") {
        self.id = id
        self.command = command
        self.args = args
        self.enabled = enabled
        self.trusted = trusted
        self.secrets = secrets
        self.about = about
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        command = try c.decode(String.self, forKey: .command)
        args = try c.decodeIfPresent([String].self, forKey: .args) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        trusted = try c.decodeIfPresent(Bool.self, forKey: .trusted) ?? false
        secrets = try c.decodeIfPresent([String].self, forKey: .secrets) ?? []
        about = try c.decodeIfPresent(String.self, forKey: .about) ?? ""
    }

    public static func secretKey(_ server: String, _ name: String) -> String { "mcp.\(server).\(name)" }

    /// Well-known open-source (MIT-licensed) servers. They run on Node, which Jarvis can install for you.
    public static let presets: [MCPServerConfig] = [
        MCPServerConfig(id: "hubspot", command: "npx", args: ["-y", "@hubspot/mcp-server"], secrets: ["PRIVATE_APP_ACCESS_TOKEN"],
                        about: "Contacts, companies and deals. Token: HubSpot, Settings, Integrations, Private apps."),
        MCPServerConfig(id: "notion", command: "npx", args: ["-y", "@notionhq/notion-mcp-server"], secrets: ["NOTION_TOKEN"],
                        about: "Pages and databases. Token: notion.so/my-integrations, then share pages with it."),
        MCPServerConfig(id: "airtable", command: "npx", args: ["-y", "airtable-mcp-server"], secrets: ["AIRTABLE_API_KEY"],
                        about: "Bases, tables and records. Token: airtable.com/create/tokens."),
        MCPServerConfig(id: "slack", command: "npx", args: ["-y", "@modelcontextprotocol/server-slack"], secrets: ["SLACK_BOT_TOKEN", "SLACK_TEAM_ID"],
                        about: "Channels and messages. Needs a Slack app's bot token and your workspace ID."),
        MCPServerConfig(id: "github", command: "npx", args: ["-y", "@modelcontextprotocol/server-github"], secrets: ["GITHUB_PERSONAL_ACCESS_TOKEN"],
                        about: "Issues, pull requests and repositories. Token: github.com/settings/tokens."),
        MCPServerConfig(id: "postgres", command: "npx", args: ["-y", "@modelcontextprotocol/server-postgres", "postgresql://localhost/postgres"],
                        about: "Read-only queries on a Postgres database; edit the connection address after adding."),
        MCPServerConfig(id: "files", command: "npx", args: ["-y", "@modelcontextprotocol/server-filesystem", "~/Documents"]),
        MCPServerConfig(id: "memory", command: "npx", args: ["-y", "@modelcontextprotocol/server-memory"]),
        MCPServerConfig(id: "browser", command: "npx", args: ["-y", "@playwright/mcp@latest"]),
    ]
}

public struct MCPTool: @unchecked Sendable {
    public let server: String
    public let name: String
    public let description: String
    public let schema: [String: Any]

    /// Name shown to the model: letters, digits and underscores only, at most 64 characters.
    public var exposedName: String {
        func clean(_ s: String) -> String { String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
        return String("mcp_\(clean(server))__\(clean(name))".prefix(64))
    }
}

public enum MCPError: Error, LocalizedError {
    case timeout(String), closed, server(String)
    public var errorDescription: String? {
        switch self {
        case .timeout(let m): return "The tool server didn't answer \(m) in time."
        case .closed: return "The tool server stopped."
        case .server(let m): return m
        }
    }
}

final class MCPClient: @unchecked Sendable {
    let config: MCPServerConfig
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var nextID = 0
    private let lock = NSLock()
    private(set) var tools: [MCPTool] = []

    init(config: MCPServerConfig) { self.config = config }

    var running: Bool { process?.isRunning ?? false }

    func start() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [config.command] + config.args.map { ($0 as NSString).expandingTildeInPath }
        var env = ProcessInfo.processInfo.environment
        // Apps launched from Finder get a minimal PATH; add the usual tool locations so npx and uvx resolve.
        env["PATH"] = [NodeRuntime.bin.path, "/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", env["PATH"] ?? ""]
            .joined(separator: ":")
        // Access tokens come from the Keychain only when the server starts.
        for name in config.secrets {
            if let v = Keychain.get(MCPServerConfig.secretKey(config.id, name)), !v.isEmpty { env[name] = v }
        }
        p.environment = env
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.receive(h.availableData) }
        errPipe.fileHandleForReading.readabilityHandler = { h in _ = h.availableData }
        p.terminationHandler = { [weak self] _ in self?.failAll() }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting

        _ = try await request("initialize", [
            "protocolVersion": "2025-06-18",
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Jarvis", "version": "0.3"],
        ], timeout: 60)
        send(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let listed = try await request("tools/list", [:], timeout: 30)
        tools = (listed["tools"] as? [[String: Any]] ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            return MCPTool(server: config.id, name: name, description: t["description"] as? String ?? "",
                           schema: t["inputSchema"] as? [String: Any] ?? ["type": "object"])
        }
    }

    func call(_ name: String, _ args: [String: Any]) async throws -> String {
        let r = try await request("tools/call", ["name": name, "arguments": args], timeout: 120)
        let parts = (r["content"] as? [[String: Any]] ?? []).map { c -> String in
            switch c["type"] as? String {
            case "text": return c["text"] as? String ?? ""
            case "image": return "[image]"
            case "resource": return ((c["resource"] as? [String: Any])?["text"] as? String) ?? "[resource]"
            default: return ""
            }
        }
        let text = parts.joined(separator: "\n")
        let clipped = text.count > 8000 ? String(text.prefix(8000)) + "\n[truncated]" : text
        return (r["isError"] as? Bool ?? false) ? "Error: \(clipped)" : (clipped.isEmpty ? "(done)" : clipped)
    }

    func stop() {
        process?.terminate()
        process = nil
    }

    private func send(_ msg: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return }
        data.append(0x0A)
        input?.write(data)
    }

    private func request(_ method: String, _ params: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        return try await withCheckedThrowingContinuation { cont in
            lock.withLock { pending[id] = cont }
            send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, .failure(MCPError.timeout(method)))
            }
        }
    }

    private func resolve(_ id: Int, _ result: Result<[String: Any], Error>) {
        lock.lock()
        let cont = pending.removeValue(forKey: id)
        lock.unlock()
        cont?.resume(with: result)
    }

    private func failAll() {
        lock.lock()
        let all = pending
        pending.removeAll()
        lock.unlock()
        all.values.forEach { $0.resume(throwing: MCPError.closed) }
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            guard let msg = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = msg["id"] as? Int, msg["method"] == nil {
                if let err = msg["error"] as? [String: Any] {
                    resolve(id, .failure(MCPError.server(err["message"] as? String ?? "Tool server error")))
                } else {
                    resolve(id, .success(msg["result"] as? [String: Any] ?? [:]))
                }
            } else if let id = msg["id"], msg["method"] as? String == "ping" {
                send(["jsonrpc": "2.0", "id": id, "result": [String: Any]()])
            }
        }
    }
}

/// Starts configured servers on first use and keeps them running while Jarvis is open.
public final class MCPHub: @unchecked Sendable {
    public static let shared = MCPHub()
    private var clients: [String: MCPClient] = [:]
    private let lock = NSLock()

    public func tools(for configs: [MCPServerConfig], log: @Sendable (String) -> Void) async -> [MCPTool] {
        var out: [MCPTool] = []
        for cfg in configs where cfg.enabled {
            var client = lock.withLock { () -> MCPClient? in
                let c = clients[cfg.id]
                if c?.config != cfg { c?.stop(); return nil }
                return c
            }
            if client == nil || !(client!.running) {
                let c = MCPClient(config: cfg)
                do {
                    log("Starting tool server \(cfg.id)")
                    try await c.start()
                    lock.withLock { clients[cfg.id] = c }
                    client = c
                } catch {
                    c.stop()
                    log("Tool server \(cfg.id) failed: \(error.localizedDescription)")
                    continue
                }
            }
            out += client?.tools ?? []
        }
        return out
    }

    public func call(_ tool: MCPTool, _ args: [String: Any]) async -> String {
        let c = lock.withLock { clients[tool.server] }
        guard let c else { return "That tool server isn't running." }
        do { return try await c.call(tool.name, args) } catch { return "Couldn't use \(tool.name): \(error.localizedDescription)" }
    }

    public func stopAll() {
        lock.lock()
        clients.values.forEach { $0.stop() }
        clients.removeAll()
        lock.unlock()
    }
}

public enum SchemaConvert {
    /// Reduces a JSON Schema to the OpenAPI subset Gemini's function declarations accept.
    public static func gemini(_ s: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        var type = s["type"] as? String
        if type == nil, let many = s["type"] as? [String] { type = many.first { $0 != "null" } }
        if type == nil, let any = (s["anyOf"] ?? s["oneOf"]) as? [[String: Any]], let first = any.first(where: { ($0["type"] as? String) != "null" }) {
            return gemini(first)
        }
        out["type"] = (type ?? "object").uppercased()
        if let d = s["description"] as? String { out["description"] = String(d.prefix(400)) }
        if let e = s["enum"] as? [Any] { out["enum"] = e.map { "\($0)" } }
        if let props = s["properties"] as? [String: Any] {
            var p: [String: Any] = [:]
            for (k, v) in props { if let d = v as? [String: Any] { p[k] = gemini(d) } }
            out["properties"] = p
            if let req = s["required"] as? [String] { out["required"] = req.filter { p[$0] != nil } }
        }
        if let items = s["items"] as? [String: Any] { out["items"] = gemini(items) }
        if out["type"] as? String == "ARRAY", out["items"] == nil { out["items"] = ["type": "STRING"] }
        if out["type"] as? String == "OBJECT", out["properties"] == nil { out["properties"] = [String: Any]() }
        return out
    }
}
