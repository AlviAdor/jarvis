import Foundation
import AppKit

/// AppleScript written by the model, for automating almost any Mac app. Shown to the user as it runs.
public enum Scripting {
    static let riskyWords = [
        "do shell script", "delete", "empty trash", "empty the trash", "send", "keystroke", "key code", "password",
        "shut down", "restart", "log out", "erase", "remove", "move to trash", "sudo", "rm -", "format", "purchase", "buy",
    ]

    /// Scripts that delete, send, type, run shell commands or power the Mac off always ask first.
    public static func isRisky(_ script: String) -> Bool {
        let s = script.lowercased()
        return riskyWords.contains { s.contains($0) }
    }

    public static func run(_ script: String) async -> String {
        let out = await AppleScript.run(script)
        if out.contains("Not authorized to send Apple events") || out.contains("-1743") {
            return "Error: macOS hasn't allowed Jarvis to control that app. Allow it in System Settings, Privacy and Security, Automation."
        }
        if out.contains("execution error") || out.contains("syntax error") { return "Error: " + out }
        return out
    }
}

/// The page you're looking at in your browser, so "summarise this" works.
public enum Browser {
    static let chromium = ["Google Chrome", "Arc", "Microsoft Edge", "Brave Browser", "Vivaldi", "Opera"]

    /// The browser in front, or the first one that's open.
    static func active() -> String? {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
        if let front = NSWorkspace.shared.frontmostApplication?.localizedName, front == "Safari" || chromium.contains(front) { return front }
        return (["Safari"] + chromium).first { running.contains($0) }
    }

    public static func current() async -> String {
        guard let b = active() else { return "No browser is open." }
        let script = b == "Safari"
            ? "tell application \"Safari\" to return (name of current tab of front window) & linefeed & (URL of current tab of front window)"
            : "tell application \"\(b)\" to return (title of active tab of front window) & linefeed & (URL of active tab of front window)"
        let out = await Scripting.run(script)
        return out.hasPrefix("Error") ? out : "\(b): \(out)"
    }

    public static func tabs() async -> String {
        guard let b = active() else { return "No browser is open." }
        let title = b == "Safari" ? "name" : "title"
        return await Scripting.run("""
        tell application "\(b)"
            set out to ""
            repeat with t in tabs of front window
                set out to out & (\(title) of t) & " | " & (URL of t) & linefeed
            end repeat
            return out
        end tell
        """)
    }

    public static func open(_ url: String) async -> String {
        guard let u = URL(string: url), ["http", "https"].contains(u.scheme ?? "") else { return "Only http and https links can be opened." }
        await MainActor.run { _ = NSWorkspace.shared.open(u) }
        return "Opened \(u.host ?? url)."
    }
}

/// Moving, copying, renaming, zipping: your own files only, never system or hidden folders.
public enum FileOps {
    static func url(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).standardizedFileURL }

    /// Same rule as the Trash: inside the home folder, not Library, not hidden.
    public static func allowed(_ p: String) -> Bool {
        let path = url(p).resolvingSymlinksInPath().path
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return false }
        let rel = path.dropFirst(home.count + 1)
        let parts = rel.split(separator: "/")
        guard let top = parts.first, top != "Library" else { return false }
        return !parts.contains { $0.hasPrefix(".") }
    }

    /// A free name next to `dest`, so nothing is ever overwritten.
    static func free(_ dest: URL) -> URL {
        var d = dest
        var n = 2
        let base = dest.deletingPathExtension().lastPathComponent, ext = dest.pathExtension
        while FileManager.default.fileExists(atPath: d.path) {
            d = dest.deletingLastPathComponent().appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return d
    }

    public static func perform(_ action: String, from: String, to: String, name: String) async -> String {
        let fm = FileManager.default
        switch action {
        case "make_folder":
            let dir = url(to.isEmpty ? from : to)
            let target = name.isEmpty ? dir : dir.appendingPathComponent(name)
            guard allowed(target.path) else { return "Only folders inside your home folder (not Library) can be made." }
            do { try fm.createDirectory(at: target, withIntermediateDirectories: true); return "Made \(target.lastPathComponent)." }
            catch { return "Couldn't make the folder: \(error.localizedDescription)" }
        case "move", "copy", "rename":
            let src = url(from)
            guard allowed(src.path), fm.fileExists(atPath: src.path) else { return "That file isn't in your home folder or doesn't exist." }
            var dest: URL
            if action == "rename" {
                guard !name.isEmpty, !name.contains("/") else { return "Give a new name without slashes." }
                dest = src.deletingLastPathComponent().appendingPathComponent(name)
            } else {
                var isDir: ObjCBool = false
                dest = url(to)
                if fm.fileExists(atPath: dest.path, isDirectory: &isDir), isDir.boolValue { dest = dest.appendingPathComponent(src.lastPathComponent) }
            }
            guard allowed(dest.path) else { return "Files can only go somewhere inside your home folder (not Library)." }
            dest = free(dest)
            do {
                try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
                if action == "copy" { try fm.copyItem(at: src, to: dest) } else { try fm.moveItem(at: src, to: dest) }
                return "\(action == "copy" ? "Copied" : action == "rename" ? "Renamed" : "Moved") to \(dest.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))."
            } catch {
                return "Couldn't \(action) it: \(error.localizedDescription)"
            }
        case "zip":
            let src = url(from)
            guard allowed(src.path), fm.fileExists(atPath: src.path) else { return "That isn't in your home folder or doesn't exist." }
            let dest = free(src.deletingLastPathComponent().appendingPathComponent(src.lastPathComponent + ".zip"))
            _ = await Run.capture("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", src.path, dest.path], timeout: 300)
            return fm.fileExists(atPath: dest.path) ? "Zipped to \(dest.lastPathComponent)." : "Couldn't zip it."
        case "unzip":
            let src = url(from)
            guard allowed(src.path), src.pathExtension.lowercased() == "zip" else { return "Give a .zip file in your home folder." }
            let dest = free(src.deletingPathExtension())
            _ = await Run.capture("/usr/bin/ditto", ["-x", "-k", src.path, dest.path], timeout: 300)
            return fm.fileExists(atPath: dest.path) ? "Unzipped into \(dest.lastPathComponent)." : "Couldn't unzip it."
        default:
            return "File actions: move, copy, rename, make_folder, zip, unzip."
        }
    }
}
