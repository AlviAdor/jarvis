import Foundation
import CryptoKit

/// Node.js for tool servers (connectors), installed into Jarvis's own folder: no admin rights, nothing
/// system-wide. The download comes from nodejs.org and is checked against its published checksums.
public enum NodeRuntime {
    static var dir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis/node")
    }
    public static var bin: URL { dir.appendingPathComponent("current/bin") }

    public static var installed: Bool {
        FileManager.default.isExecutableFile(atPath: bin.appendingPathComponent("node").path)
            || ["/opt/homebrew/bin/node", "/usr/local/bin/node"].contains { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func install(progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Finding the current Node.js LTS…")
        let (indexData, _) = try await URLSession.shared.data(from: URL(string: "https://nodejs.org/dist/index.json")!)
        guard let index = try JSONSerialization.jsonObject(with: indexData) as? [[String: Any]],
              let lts = index.first(where: { ($0["lts"] as? String) != nil }), let version = lts["version"] as? String else {
            throw LLMError.other("Couldn't read the Node.js release list.")
        }
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafeBytes(of: &uts.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let arch = machine.contains("arm64") ? "arm64" : "x64"
        let name = "node-\(version)-darwin-\(arch).tar.gz"
        let base = "https://nodejs.org/dist/\(version)/"

        progress("Downloading Node.js \(version)…")
        let (sums, _) = try await URLSession.shared.data(from: URL(string: base + "SHASUMS256.txt")!)
        guard let expected = String(decoding: sums, as: UTF8.self).split(separator: "\n")
                .first(where: { $0.hasSuffix(" " + name) })?.split(separator: " ").first.map(String.init) else {
            throw LLMError.other("Node.js didn't publish a checksum for \(name).")
        }
        let (tmp, _) = try await URLSession.shared.download(from: URL(string: base + name)!)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let actual = SHA256.hash(data: try Data(contentsOf: tmp)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw LLMError.other("The Node.js download didn't match its checksum, so it wasn't installed.") }

        progress("Installing…")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = await Run.capture("/usr/bin/tar", ["-xzf", tmp.path, "-C", dir.path], timeout: 300)
        let unpacked = dir.appendingPathComponent(name.replacingOccurrences(of: ".tar.gz", with: ""))
        guard FileManager.default.fileExists(atPath: unpacked.path) else { throw LLMError.other("Couldn't unpack Node.js. \(out)") }
        let current = dir.appendingPathComponent("current")
        try? FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: unpacked)
        progress("Node.js \(version) is ready.")
    }
}
