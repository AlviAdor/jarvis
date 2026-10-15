import Foundation
import AppKit
import ApplicationServices
import Vision

/// Gives the model a text map of what's on screen: real controls from the Accessibility tree of the
/// frontmost window, with on-device text recognition as a fallback for apps that expose little.
/// Coordinates use the same 0-1000 grid as the computer tool.
public enum ScreenReader {
    private static let roles: Set<String> = [
        "AXButton", "AXTextField", "AXTextArea", "AXLink", "AXMenuItem", "AXMenuBarItem", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXMenuButton", "AXCell", "AXStaticText",
        "AXSlider", "AXDisclosureTriangle", "AXImage", "AXSearchField",
    ]
    public static let marker = "\n\nOn screen now:"

    private static func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String {
        (attr(el, name) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func frame(_ el: AXUIElement) -> CGRect? {
        guard let p = attr(el, kAXPositionAttribute), let s = attr(el, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(p as! AXValue, .cgPoint, &point)
        AXValueGetValue(s as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    /// Lines like `button "Send" @ 812,940`, limited so a step stays cheap.
    public static func controls(screen: CGSize, limit: Int = 70) -> [String] {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return [] }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.4)
        let bounds = CGRect(origin: .zero, size: screen)
        var out: [String] = []
        var visited = 0

        func walk(_ el: AXUIElement, depth: Int) {
            guard depth < 16, visited < 1500, out.count < limit else { return }
            visited += 1
            let role = string(el, kAXRoleAttribute)
            if roles.contains(role), let f = frame(el), f.width > 3, f.height > 3, bounds.intersects(f) {
                let secure = string(el, kAXSubroleAttribute) == "AXSecureTextField"
                var label = [kAXTitleAttribute, kAXDescriptionAttribute, "AXPlaceholderValue", kAXHelpAttribute]
                    .lazy.map { string(el, $0) }.first { !$0.isEmpty } ?? ""
                if label.isEmpty, !secure, role == "AXStaticText" || role == "AXTextField" || role == "AXTextArea" {
                    label = string(el, kAXValueAttribute)
                }
                if secure { label = "password field" }
                let isField = role == "AXTextField" || role == "AXTextArea" || role == "AXSearchField"
                if !label.isEmpty || isField {
                    let name = role.dropFirst(2).lowercased()
                    let x = Int((f.midX / screen.width * 1000).rounded()), y = Int((f.midY / screen.height * 1000).rounded())
                    out.append("\(name) \"\(label.prefix(60))\" @ \(x),\(y)")
                }
            }
            for c in children(el) { walk(c, depth: depth + 1) }
        }

        if let w = attr(root, kAXFocusedWindowAttribute), CFGetTypeID(w) == AXUIElementGetTypeID() {
            walk(w as! AXUIElement, depth: 0)
        } else {
            walk(root, depth: 0)
        }
        return out
    }

    /// Text recognized in the screenshot, on this Mac, top to bottom.
    public static func text(in image: CGImage, limit: Int = 60) -> [String] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .fast
        req.usesLanguageCorrection = false
        try? VNImageRequestHandler(cgImage: image).perform([req])
        let lines = (req.results ?? []).compactMap { obs -> (String, CGRect)? in
            guard let t = obs.topCandidates(1).first?.string, t.count > 1 else { return nil }
            return (t, obs.boundingBox)
        }
        return lines
            .sorted { $0.1.midY > $1.1.midY }
            .prefix(limit)
            .map { t, b in "text \"\(t.prefix(60))\" @ \(Int(b.midX * 1000)),\(Int((1 - b.midY) * 1000))" }
    }

    /// Appended to every observation the model receives during screen control.
    public static func describe(_ shot: Shot, screen: CGSize) -> String {
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "unknown app"
        var lines = controls(screen: screen)
        if lines.count < 8, let img = shot.image { lines += text(in: img) }
        guard !lines.isEmpty else { return "\(marker) \(app) (no readable controls; use the screenshot)" }
        return "\(marker) \(app)\n" + lines.joined(separator: "\n")
    }

    /// Drops the screen map from an older observation, keeping the action result.
    public static func strip(_ s: String) -> String {
        guard let r = s.range(of: marker) else { return s }
        return String(s[..<r.lowerBound])
    }
}
