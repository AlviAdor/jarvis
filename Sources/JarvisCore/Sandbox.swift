import Foundation

/// Runs shell commands under sandbox-exec: no network, no writes outside a scratch folder,
/// and no reads of credential directories.
public enum Sandbox {
    public static let scratch: URL = {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-scratch")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    static func profile() -> String {
        let home = NSHomeDirectory()
        let secret = [".ssh", ".aws", ".gnupg", ".config/gh", "Library/Keychains"]
            .map { "(subpath \"\(home)/\($0)\")" }.joined(separator: " ")
        return """
        (version 1)
        (allow default)
        (deny network*)
        (deny file-write*)
        (allow file-write* (subpath "\(scratch.path)") (subpath "/private\(scratch.path)") (literal "/dev/null"))
        (deny file-read* \(secret))
        """
    }

    public static func run(_ command: String, timeout: TimeInterval = 15) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
                p.arguments = ["-p", profile(), "/bin/zsh", "-c", command]
                p.currentDirectoryURL = scratch
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: "Couldn't start sandbox: \(error.localizedDescription)")
                    return
                }
                let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                killer.cancel()
                var out = String(decoding: data, as: UTF8.self)
                if out.count > 6000 { out = String(out.prefix(6000)) + "\n[truncated]" }
                cont.resume(returning: out.isEmpty ? "(no output, exit \(p.terminationStatus))" : out)
            }
        }
    }
}

public enum AppleScript {
    public static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    public static func run(_ script: String) async -> String {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                p.arguments = ["-e", script]
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = pipe
                do { try p.run() } catch {
                    cont.resume(returning: "Couldn't run AppleScript.")
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                var out = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                if out.count > 6000 { out = String(out.prefix(6000)) + "\n[truncated]" }
                cont.resume(returning: out.isEmpty ? "(done)" : out)
            }
        }
    }
}

public enum Mail {
    public static func unread(limit: Int) async -> String {
        await AppleScript.run("""
        tell application "Mail"
            set out to ""
            set msgs to (messages of inbox whose read status is false)
            set n to count of msgs
            if n > \(limit) then set n to \(limit)
            repeat with i from 1 to n
                set m to item i of msgs
                set c to ""
                try
                    set c to content of m
                    if (length of c) > 300 then set c to text 1 thru 300 of c
                end try
                set out to out & "From: " & (sender of m) & " | Subject: " & (subject of m) & " | " & c & linefeed & "---" & linefeed
            end repeat
            if out is "" then return "No unread mail."
            return out
        end tell
        """)
    }

    public static func send(to: String, subject: String, body: String) async -> String {
        await AppleScript.run("""
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(AppleScript.escape(subject))", content:"\(AppleScript.escape(body))", visible:false}
            tell msg to make new to recipient with properties {address:"\(AppleScript.escape(to))"}
            send msg
        end tell
        return "Sent."
        """)
    }
}
