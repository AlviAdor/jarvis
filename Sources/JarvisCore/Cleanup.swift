import Foundation
import AppKit
import CryptoKit

/// Finds what's using disk space and frees it safely. Anything the user might want back goes to the
/// Trash; only caches and build data that apps recreate on their own are deleted outright.
public enum DiskCare {
    public struct Spot: Sendable {
        public let id: String
        public let title: String
        public let path: String
        public let regenerable: Bool   // safe to delete: apps rebuild it
    }

    public static let spots: [Spot] = [
        Spot(id: "caches", title: "App caches", path: "~/Library/Caches", regenerable: true),
        Spot(id: "logs", title: "Logs", path: "~/Library/Logs", regenerable: true),
        Spot(id: "xcode", title: "Xcode build data", path: "~/Library/Developer/Xcode/DerivedData", regenerable: true),
        Spot(id: "simulators", title: "Simulator caches", path: "~/Library/Developer/CoreSimulator/Caches", regenerable: true),
        Spot(id: "devicesupport", title: "iOS device support files", path: "~/Library/Developer/Xcode/iOS DeviceSupport", regenerable: true),
        Spot(id: "npm", title: "npm cache", path: "~/.npm/_cacache", regenerable: true),
        Spot(id: "brew", title: "Homebrew downloads", path: "~/Library/Caches/Homebrew", regenerable: true),
        Spot(id: "trash", title: "Trash", path: "~/.Trash", regenerable: false),
        Spot(id: "downloads", title: "Downloads", path: "~/Downloads", regenerable: false),
        Spot(id: "movies", title: "Movies", path: "~/Movies", regenerable: false),
        Spot(id: "archives", title: "Xcode archives", path: "~/Library/Developer/Xcode/Archives", regenerable: false),
        Spot(id: "backups", title: "iPhone and iPad backups", path: "~/Library/Application Support/MobileSync/Backup", regenerable: false),
    ]

    static func expand(_ p: String) -> URL { URL(fileURLWithPath: (p as NSString).expandingTildeInPath) }

    /// Size on disk in bytes, or nil when the folder is missing or macOS won't let Jarvis look.
    public static func size(of url: URL) async -> Int64? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let out = await Run.capture("/usr/bin/du", ["-sk", url.path], timeout: 25)
        guard let kb = out.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) else { return nil }
        return kb * 1024
    }

    public static func freeSpace() -> Int64 { SystemMonitor.shared.freeSpaceNow() }

    // MARK: Report

    public static func report() async -> String {
        let sizes = await withTaskGroup(of: (Int, Int64?).self) { g in
            for (i, s) in spots.enumerated() { g.addTask { (i, await size(of: expand(s.path))) } }
            var out = [Int: Int64?]()
            for await (i, n) in g { out[i] = n }
            return out
        }
        var lines = ["Free space: \(SystemMonitor.bytes(freeSpace()))."]
        var reclaimable: Int64 = 0
        for (i, s) in spots.enumerated() {
            guard let n = sizes[i] ?? nil, n > 5_000_000 else { continue }
            if s.regenerable { reclaimable += n }
            lines.append("- \(s.title) (\(s.id)): \(SystemMonitor.bytes(n))" + (s.regenerable ? ", safe to clear" : ", needs review"))
        }
        let old = oldDownloads(days: 60)
        if !old.isEmpty {
            lines.append("- Downloads untouched for 60+ days (old_downloads): \(old.count) items, \(SystemMonitor.bytes(old.reduce(0) { $0 + $1.size }))")
        }
        lines.append("Clearing the safe items would free about \(SystemMonitor.bytes(reclaimable)).")
        lines.append("Folders macOS keeps private (Trash, Mail, backups) show up only if Jarvis has Full Disk Access.")
        return lines.joined(separator: "\n")
    }

    // MARK: Finding things

    public struct Found: Sendable {
        public let path: String
        public let size: Int64
        public let lastUsed: Date?
    }

    /// Big files in the home folder, found with Spotlight so nothing is scanned by hand.
    public static func largeFiles(minMB: Int = 500, limit: Int = 20) async -> [Found] {
        let out = await Run.capture("/usr/bin/mdfind", ["-onlyin", NSHomeDirectory(), "kMDItemFSSize > \(minMB * 1_000_000)"], timeout: 20)
        let lib = NSHomeDirectory() + "/Library/"
        return out.split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix(lib) && !$0.contains("/.") }
            .compactMap { path -> Found? in
                let url = URL(fileURLWithPath: path)
                let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isDirectoryKey, .contentAccessDateKey])
                guard v?.isDirectory != true, let n = v?.totalFileAllocatedSize else { return nil }
                return Found(path: path, size: Int64(n), lastUsed: v?.contentAccessDate)
            }
            .sorted { $0.size > $1.size }
            .prefix(limit)
            .map { $0 }
    }

    /// Items in Downloads nobody has opened or changed for a while.
    public static func oldDownloads(days: Int) -> [Found] {
        let dir = expand("~/Downloads")
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .contentAccessDateKey, .totalFileAllocatedSizeKey, .addedToDirectoryDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return items.compactMap { url in
            let v = try? url.resourceValues(forKeys: Set(keys))
            let recent = [v?.contentModificationDate, v?.contentAccessDate, v?.addedToDirectoryDate].compactMap { $0 }.max() ?? .distantPast
            guard recent < cutoff else { return nil }
            return Found(path: url.path, size: Int64(v?.totalFileAllocatedSize ?? 0), lastUsed: recent)
        }
    }

    /// Identical files in a folder, matched by size and then by content hash.
    public static func duplicates(in folder: URL, maxFiles: Int = 4000) -> [[Found]] {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                    options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var bySize: [Int: [URL]] = [:]
        var seen = 0
        for case let url as URL in e {
            guard seen < maxFiles else { break }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard v?.isRegularFile == true, let n = v?.fileSize, n > 100_000 else { continue }
            seen += 1
            bySize[n, default: []].append(url)
        }
        var groups: [[Found]] = []
        for (n, urls) in bySize where urls.count > 1 {
            var byHash: [String: [URL]] = [:]
            for u in urls { if let h = hash(u) { byHash[h, default: []].append(u) } }
            for (_, same) in byHash where same.count > 1 {
                groups.append(same.map { Found(path: $0.path, size: Int64(n), lastUsed: nil) })
            }
        }
        return groups.sorted { ($0.first?.size ?? 0) * Int64($0.count) > ($1.first?.size ?? 0) * Int64($1.count) }
    }

    static func hash(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var sha = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { sha.update(data: chunk) }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Safety

    /// Only the user's own files may be moved to the Trash: nothing in Library, no hidden folders,
    /// and never the standard folders themselves.
    public static func canTrash(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let p = url.path
        guard p.hasPrefix(home + "/") else { return false }
        let rel = String(p.dropFirst(home.count + 1))
        let parts = rel.split(separator: "/")
        guard let top = parts.first, parts.count >= 2 else { return false }   // not a top-level folder itself
        if top == "Library" || top.hasPrefix(".") { return false }
        if parts.contains(where: { $0.hasPrefix(".") }) { return false }
        if rel.contains(".photoslibrary") || rel.contains(".musiclibrary") { return false }
        return true
    }

    /// Moves files to the Trash so they can be put back.
    public static func trash(_ paths: [String]) async -> (moved: Int, bytes: Int64, skipped: [String]) {
        var moved = 0
        var bytes: Int64 = 0
        var skipped: [String] = []
        for p in paths {
            let url = expand(p)
            guard canTrash(url.path), FileManager.default.fileExists(atPath: url.path) else { skipped.append(p); continue }
            let n = await size(of: url) ?? 0
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
                bytes += n
            } catch {
                skipped.append(p)
            }
        }
        return (moved, bytes, skipped)
    }

    // MARK: Cleaning

    public static let cleanTargets = ["caches", "logs", "xcode", "simulators", "devicesupport", "npm", "brew", "trash", "old_downloads"]

    /// Frees space in one place and reports what changed. The caller asks the user first.
    public static func clean(_ target: String, days: Int = 60) async -> String {
        let before = freeSpace()
        var note = ""
        switch target {
        case "caches":
            let running = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
            let n = removeChildren(of: expand("~/Library/Caches")) { name in
                let l = name.lowercased()
                return !l.hasPrefix("com.apple.") && !running.contains(l) && l != (Bundle.main.bundleIdentifier ?? "").lowercased()
            }
            note = "Cleared \(n) app caches (skipped Apple's and those of apps that are open)."
        case "logs":
            let n = removeChildren(of: expand("~/Library/Logs")) { _ in true }
            note = "Removed \(n) log folders."
        case "xcode":
            if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleIdentifier == "com.apple.dt.Xcode" }) {
                return "Xcode is open. Quit it first, then ask again."
            }
            let n = removeChildren(of: expand("~/Library/Developer/Xcode/DerivedData")) { _ in true }
            note = "Removed build data for \(n) projects. Xcode rebuilds it when needed."
        case "simulators":
            let n = removeChildren(of: expand("~/Library/Developer/CoreSimulator/Caches")) { _ in true }
            if FileManager.default.fileExists(atPath: "/usr/bin/xcrun") {
                _ = await Run.capture("/usr/bin/xcrun", ["simctl", "delete", "unavailable"], timeout: 60)
            }
            note = "Cleared \(n) simulator caches and removed simulators for runtimes no longer installed."
        case "devicesupport":
            let dir = expand("~/Library/Developer/Xcode/iOS DeviceSupport")
            func modified(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
            let items = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
                .sorted { modified($0) > modified($1) }
            var n = 0
            for old in items.dropFirst(2) where (try? FileManager.default.removeItem(at: old)) != nil { n += 1 }
            note = "Removed support files for \(n) older iOS versions and kept the two newest."
        case "npm":
            if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/npm") || FileManager.default.fileExists(atPath: "/usr/local/bin/npm") {
                _ = await Run.capture("/usr/bin/env", ["npm", "cache", "clean", "--force"], timeout: 120)
            } else {
                try? FileManager.default.removeItem(at: expand("~/.npm/_cacache"))
            }
            note = "Cleared the npm cache."
        case "brew":
            let brew = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.fileExists(atPath: $0) }
            guard let brew else { return "Homebrew isn't installed." }
            _ = await Run.capture(brew, ["cleanup", "--prune=all", "-s"], timeout: 300)
            note = "Ran Homebrew cleanup."
        case "trash":
            let out = await AppleScript.run("tell application \"Finder\" to empty the trash")
            if out.lowercased().contains("error") || out.contains("not allowed") { return "macOS didn't let me empty the Trash: \(out)" }
            note = "Emptied the Trash."
        case "old_downloads":
            let old = oldDownloads(days: days)
            let r = await trash(old.map(\.path))
            note = "Moved \(r.moved) old downloads (\(SystemMonitor.bytes(r.bytes))) to the Trash. Empty the Trash to free the space."
        default:
            return "I can clean: \(cleanTargets.joined(separator: ", "))."
        }
        try? await Task.sleep(nanoseconds: 500_000_000)
        let freed = max(0, freeSpace() - before)
        return note + (freed > 1_000_000 ? " Freed \(SystemMonitor.bytes(freed)); \(SystemMonitor.bytes(freeSpace())) is free now." : "")
    }

    /// What a clean would touch, for the confirmation dialog.
    public static func describe(_ target: String, days: Int = 60) async -> String {
        if target == "old_downloads" {
            let old = oldDownloads(days: days)
            return "Move \(old.count) downloads untouched for \(days)+ days (\(SystemMonitor.bytes(old.reduce(0) { $0 + $1.size }))) to the Trash?"
        }
        guard let spot = spots.first(where: { $0.id == target }) else { return "Clean \(target)?" }
        let n = await size(of: expand(spot.path))
        let size = n.map { " (\(SystemMonitor.bytes($0)))" } ?? ""
        switch target {
        case "trash": return "Permanently empty the Trash\(size)? This can't be undone."
        default: return "Delete \(spot.title.lowercased())\(size)? Apps recreate these as needed."
        }
    }

    private static func removeChildren(of dir: URL, where keep: (String) -> Bool) -> Int {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        for item in items where keep(item.lastPathComponent) {
            if (try? FileManager.default.removeItem(at: item)) != nil { n += 1 }
        }
        return n
    }
}

/// Sorts a messy folder into tidy subfolders by kind, with a one-step undo.
public enum Organizer {
    static let kinds: [(String, Set<String>)] = [
        ("Images", ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef", "arw", "dng", "psd", "ai", "avif"]),
        ("Videos", ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]),
        ("Audio", ["mp3", "m4a", "wav", "aac", "flac", "aiff", "aif", "ogg", "opus"]),
        ("PDFs", ["pdf"]),
        ("Documents", ["doc", "docx", "pages", "txt", "rtf", "rtfd", "md", "odt", "epub", "tex"]),
        ("Spreadsheets", ["xls", "xlsx", "numbers", "csv", "tsv", "ods"]),
        ("Presentations", ["ppt", "pptx", "key", "odp"]),
        ("Archives", ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz"]),
        ("Installers", ["dmg", "pkg", "mpkg", "iso"]),
        ("Code", ["swift", "py", "js", "ts", "tsx", "jsx", "html", "css", "json", "java", "kt", "c", "cpp", "h", "m", "sh", "rb", "go", "rs", "ipynb", "sql", "yml", "yaml", "xml", "php"]),
        ("Fonts", ["ttf", "otf", "woff", "woff2"]),
    ]
    static let unfinished: Set<String> = ["crdownload", "download", "part", "partial", "tmp"]

    public static func kind(of name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let lower = name.lowercased()
        if lower.hasPrefix("screenshot") || lower.hasPrefix("screen shot") || lower.hasPrefix("screen recording") { return "Screenshots" }
        return kinds.first { $0.1.contains(ext) }?.0 ?? "Other"
    }

    public struct Plan: Sendable {
        public let folder: String
        public let moves: [(from: String, to: String)]
        public var counts: [String: Int] {
            moves.reduce(into: [:]) { $0[(($1.to as NSString).deletingLastPathComponent as NSString).lastPathComponent, default: 0] += 1 }
        }
        public var summary: String {
            guard !moves.isEmpty else { return "\((folder as NSString).lastPathComponent) is already tidy." }
            let parts = counts.sorted { $0.value > $1.value }.map { "\($0.value) to \($0.key)" }
            return "Sort \(moves.count) items in \((folder as NSString).lastPathComponent): " + parts.joined(separator: ", ") + "."
        }
    }

    /// Folders Jarvis may organise: anything in the home folder except Library, hidden folders and home itself.
    public static func allowed(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
        let home = NSHomeDirectory()
        guard url.path.hasPrefix(home + "/") else { return nil }
        let rel = url.path.dropFirst(home.count + 1)
        if rel.hasPrefix("Library") || rel.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return url
    }

    public static func plan(_ folder: URL) -> Plan {
        let names = Set(kinds.map(\.0) + ["Screenshots", "Other"])
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                                   options: [.skipsHiddenFiles])) ?? []
        var moves: [(String, String)] = []
        var taken = Set<String>()
        for item in items {
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if v?.isDirectory == true && v?.isPackage != true { continue }   // leave folders alone
            let name = item.lastPathComponent
            if names.contains(name) || unfinished.contains(item.pathExtension.lowercased()) { continue }
            let dest = folder.appendingPathComponent(kind(of: name))
            var target = dest.appendingPathComponent(name)
            var n = 2
            while FileManager.default.fileExists(atPath: target.path) || taken.contains(target.path) {
                let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
                target = dest.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
                n += 1
            }
            taken.insert(target.path)
            moves.append((item.path, target.path))
        }
        return Plan(folder: folder.path, moves: moves)
    }

    /// Tests point this somewhere temporary so they never touch the real undo record.
    static var undoOverride: URL?

    static var undoFile: URL {
        if let undoOverride { return undoOverride }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("organize-undo.json")
    }

    public static func apply(_ plan: Plan) -> Int {
        var done: [[String]] = []
        for m in plan.moves {
            let to = URL(fileURLWithPath: m.to)
            try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? FileManager.default.moveItem(at: URL(fileURLWithPath: m.from), to: to)) != nil { done.append([m.from, m.to]) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: done) { try? data.write(to: undoFile, options: .atomic) }
        return done.count
    }

    /// Puts everything from the last organise back where it was.
    public static func undo() -> Int {
        guard let data = try? Data(contentsOf: undoFile),
              let moves = try? JSONSerialization.jsonObject(with: data) as? [[String]] else { return 0 }
        var n = 0
        var emptied = Set<URL>()
        for m in moves.reversed() where m.count == 2 {
            let from = URL(fileURLWithPath: m[1]), to = URL(fileURLWithPath: m[0])
            guard !FileManager.default.fileExists(atPath: to.path) else { continue }
            if (try? FileManager.default.moveItem(at: from, to: to)) != nil {
                n += 1
                emptied.insert(from.deletingLastPathComponent())
            }
        }
        for dir in emptied where (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.filter({ $0 != ".DS_Store" }).isEmpty == true {
            try? FileManager.default.removeItem(at: dir)
        }
        try? FileManager.default.removeItem(at: undoFile)
        return n
    }
}
