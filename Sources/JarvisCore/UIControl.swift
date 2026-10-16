import Foundation
import AppKit
import ApplicationServices

/// Operates apps through macOS Accessibility: the same buttons, fields and menus a person uses, found by
/// name instead of by pixel position. Faster and far more precise than clicking on screenshots.
public enum UIControl {
    /// Elements from the last listing, so "#12" can be pressed afterwards.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var elements: [AXUIElement] = []
        var app: pid_t = 0
    }
    private static let cache = Cache()

    static let actionable: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
        "AXComboBox", "AXMenuButton", "AXLink", "AXSlider", "AXTab", "AXCell", "AXRow", "AXDisclosureTriangle",
        "AXIncrementor", "AXSegmentedControl", "AXStaticText", "AXImage", "AXMenuItem",
    ]

    static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    static func str(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    static func label(_ el: AXUIElement) -> String {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute] {
            let s = str(el, key)
            if !s.isEmpty { return s }
        }
        let role = str(el, kAXRoleAttribute)
        if role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" || role == "AXCell" {
            return String(str(el, kAXValueAttribute).prefix(80))
        }
        return ""
    }

    static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    /// The app the user is working in: the one in front, or, while Jarvis's own window is in front,
    /// the app whose window is next in line.
    public static func userApp() -> NSRunningApplication? {
        let me = ProcessInfo.processInfo.processIdentifier
        if let f = NSWorkspace.shared.frontmostApplication, f.processIdentifier != me { return f }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows where (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { continue }
            return app
        }
        return nil
    }

    static func appElement(_ name: String?) -> (AXUIElement, NSRunningApplication)? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let app: NSRunningApplication?
        if let name, !name.isEmpty {
            app = apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
                ?? apps.first { $0.localizedName?.localizedCaseInsensitiveContains(name) == true }
        } else {
            app = userApp()
        }
        guard let app else { return nil }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.6)
        return (el, app)
    }

    // MARK: Reading

    /// The controls in the app's front window, numbered, plus its menu bar's top-level menus.
    public static func list(app name: String? = nil, limit: Int = 120) -> String {
        guard AXIsProcessTrusted() else { return "Couldn't read the app: Accessibility permission is off." }
        guard let (root, app) = appElement(name) else { return "That app isn't open." }
        var found: [AXUIElement] = []
        var lines: [String] = []
        var visited = 0
        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 18, visited < 2500, found.count < limit else { return }
            visited += 1
            let role = str(el, kAXRoleAttribute)
            if actionable.contains(role) {
                let l = label(el)
                let field = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox"].contains(role)
                if !l.isEmpty || field {
                    found.append(el)
                    let kind = role.dropFirst(2).lowercased()
                    let secure = str(el, kAXSubroleAttribute) == "AXSecureTextField"
                    var line = "#\(found.count) \(kind) \"\(secure ? "password field" : String(l.prefix(70)))\""
                    if field, !secure { let v = str(el, kAXValueAttribute); if !v.isEmpty { line += " value \"\(v.prefix(40))\"" } }
                    if (attr(el, kAXEnabledAttribute) as? Bool) == false { line += " (disabled)" }
                    lines.append(line)
                }
            }
            for c in children(el) { walk(c, depth: depth + 1) }
        }
        let window = attr(root, kAXFocusedWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        if let window { walk(window, depth: 0) } else { walk(root, depth: 0) }
        cache.lock.withLock {
            cache.elements = found
            cache.app = app.processIdentifier
        }
        let menus = (attr(root, kAXMenuBarAttribute).map { children($0 as! AXUIElement) } ?? []).map { str($0, kAXTitleAttribute) }.filter { !$0.isEmpty }
        let title = window.map { str($0, kAXTitleAttribute) } ?? ""
        var out = "\(app.localizedName ?? "App")\(title.isEmpty ? "" : " · \(title)")"
        if !menus.isEmpty { out += "\nMenus: " + menus.joined(separator: ", ") }
        out += lines.isEmpty ? "\n(no labelled controls found; use the screen instead)" : "\n" + lines.joined(separator: "\n")
        return out
    }

    // MARK: Acting

    private static func target(_ ref: String, app name: String?) -> AXUIElement? {
        let r = ref.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("#"), let n = Int(r.dropFirst()) {
            return cache.lock.withLock { n >= 1 && n <= cache.elements.count ? cache.elements[n - 1] : nil }
        }
        // By label: list afresh, then pick the best match.
        _ = list(app: name)
        let els = cache.lock.withLock { cache.elements }
        let want = r.lowercased()
        return els.first { label($0).lowercased() == want } ?? els.first { label($0).lowercased().contains(want) }
    }

    /// Presses a button, link, checkbox, menu item or row.
    public static func press(_ ref: String, app: String? = nil) async -> String {
        guard let el = target(ref, app: app) else { return "Couldn't find \"\(ref)\". List the controls first." }
        let name = label(el)
        if AXUIElementPerformAction(el, kAXPressAction as CFString) == .success { return "Pressed \"\(name)\"." }
        if let f = frame(el) {
            await Input.click(at: CGPoint(x: f.midX, y: f.midY))
            return "Clicked \"\(name)\"."
        }
        return "Couldn't press \"\(name)\"."
    }

    /// Puts text into a field, replacing what's there.
    public static func setText(_ ref: String, _ text: String, app: String? = nil) async -> String {
        guard let el = target(ref, app: app) else { return "Couldn't find \"\(ref)\". List the controls first." }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        if AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success {
            return "Filled \"\(label(el).isEmpty ? "the field" : label(el))\"."
        }
        if let f = frame(el) { await Input.click(at: CGPoint(x: f.midX, y: f.midY)) }
        _ = await Input.key("cmd+a")
        await Input.type(text)
        return "Typed into \"\(label(el).isEmpty ? "the field" : label(el))\"."
    }

    /// Chooses a menu item by path, such as "File > Export as PDF…".
    public static func menu(_ path: String, app name: String? = nil) async -> String {
        guard AXIsProcessTrusted() else { return "Couldn't use the menu: Accessibility permission is off." }
        guard let (root, app) = appElement(name) else { return "That app isn't open." }
        app.activate()
        try? await Task.sleep(nanoseconds: 150_000_000)
        guard let bar = attr(root, kAXMenuBarAttribute).map({ $0 as! AXUIElement }) else { return "That app has no menu bar." }
        let parts = path.split(whereSeparator: { $0 == ">" || $0 == "›" || $0 == "→" }).map { $0.trimmingCharacters(in: .whitespaces) }
        var current = bar
        for (i, part) in parts.enumerated() {
            var items = children(current)
            // Menu bar items and submenus keep their items one level down.
            if let only = items.first, items.count == 1, str(only, kAXRoleAttribute) == "AXMenu" { items = children(only) }
            let want = part.lowercased().replacingOccurrences(of: "...", with: "…")
            guard let hit = items.first(where: { str($0, kAXTitleAttribute).lowercased().replacingOccurrences(of: "...", with: "…") == want })
                    ?? items.first(where: { str($0, kAXTitleAttribute).lowercased().hasPrefix(want) }) else {
                let options = items.map { str($0, kAXTitleAttribute) }.filter { !$0.isEmpty }.prefix(25)
                return "No \"\(part)\" in that menu. Options: \(options.joined(separator: ", "))"
            }
            if i == parts.count - 1 {
                return AXUIElementPerformAction(hit, kAXPressAction as CFString) == .success ? "Chose \(path)." : "Couldn't choose \(path)."
            }
            AXUIElementPerformAction(hit, kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: 120_000_000)
            current = hit
        }
        return "Chose \(path)."
    }

    /// Brings an app to the front.
    @MainActor
    public static func focus(_ name: String) -> String {
        guard let (_, app) = appElement(name) else { return "\(name) isn't open." }
        app.activate()
        return "Switched to \(app.localizedName ?? name)."
    }

    /// Minimise, close, zoom or make full screen the front window; or hide the app or the others.
    public static func window(_ action: String, app name: String? = nil) async -> String {
        guard AXIsProcessTrusted() else { return "Couldn't control windows: Accessibility permission is off." }
        guard let (root, app) = appElement(name) else { return "That app isn't open." }
        if action == "hide" { _ = await MainActor.run { app.hide() }; return "Hid \(app.localizedName ?? "it")." }
        if action == "hide_others" {
            await MainActor.run {
                for other in NSWorkspace.shared.runningApplications where other.activationPolicy == .regular && other != app { other.hide() }
            }
            return "Hid the other apps."
        }
        guard let w = attr(root, kAXFocusedWindowAttribute).map({ $0 as! AXUIElement }) else { return "No window to act on." }
        switch action {
        case "minimize": AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue)
        case "fullscreen": AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanTrue)
        case "close", "zoom":
            let key = action == "close" ? kAXCloseButtonAttribute : kAXZoomButtonAttribute
            guard let b = attr(w, key).map({ $0 as! AXUIElement }) else { return "That window can't be \(action == "close" ? "closed" : "zoomed")." }
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        default: return "Window actions: minimize, close, zoom, fullscreen, hide, hide_others."
        }
        return "Done."
    }
}
