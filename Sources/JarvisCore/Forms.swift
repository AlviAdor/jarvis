import Foundation
import AppKit
import ApplicationServices
import Contacts

/// Filling in forms the way a person does: read every field with its label, fill everything the user's details
/// cover in one go, and leave submitting to the user. Works on web pages (Safari, Chrome and other Chromium
/// browsers) and in Mac apps, through Accessibility.
public enum Forms {
    public enum Kind: String, Sendable { case text, multiline, choice = "select", checkbox, radio, date, secret }

    public struct Field: Sendable {
        public let id: String
        public let kind: Kind
        public let label: String
        public let placeholder: String
        public let value: String
        public let options: [String]
        public let required: Bool
    }

    /// The form from the last reading, so its fields can be filled by id afterwards.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var elements: [String: AXUIElement] = [:]
        var fields: [Field] = []
        var pid: pid_t = 0
        var app = ""
        var web = false
    }
    private static let cache = Cache()

    public static var lastApp: String { cache.lock.withLock { cache.app } }

    /// Fields Jarvis never fills, whatever it's told: passwords, payment cards and one-time codes.
    public static func isSensitive(_ label: String) -> Bool {
        let l = " " + label.lowercased() + " "
        return ["password", "passcode", "passphrase", "card number", "credit card", "debit card", "cvv", "cvc", "security code",
                "one-time code", "one time code", "verification code", " otp ", "2fa", " pin "].contains { l.contains($0) }
    }

    static let fieldRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXPopUpButton", "AXCheckBox", "AXRadioButton", "AXDateField", "AXDateTimeArea"]

    // MARK: Reading

    /// Reads the form in the app the user is working in, or the named app.
    public static func read(app name: String? = nil) async -> String {
        guard AXIsProcessTrusted() else { return "Couldn't read the form: Accessibility permission is off." }
        guard let (root, app) = UIControl.appElement(name) else { return "That app isn't open." }
        let appName = app.localizedName ?? "the app"
        let browser = appName == "Safari" || Browser.chromium.contains(appName)
        // Chromium browsers only build the page's accessibility tree when an assistant asks for it.
        if Browser.chromium.contains(appName) { AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue) }
        var (fields, elements, buttons, title) = scan(root, browser: browser)
        if fields.isEmpty, Browser.chromium.contains(appName) {
            try? await Task.sleep(nanoseconds: 700_000_000)
            (fields, elements, buttons, title) = scan(root, browser: browser)
        }
        cache.lock.withLock {
            cache.elements = elements
            cache.fields = fields
            cache.pid = app.processIdentifier
            cache.app = appName
            cache.web = browser
        }
        guard !fields.isEmpty else {
            return "No form fields found in \(appName)\(title.isEmpty ? "" : " · \(title)"). Make sure the form is open and in front; for a page that draws its own controls, use the screen instead."
        }
        return describe(fields, app: appName, title: title, buttons: buttons)
    }

    /// One line per field, in the order they appear.
    static func describe(_ fields: [Field], app: String, title: String, buttons: [String]) -> String {
        var lines = ["Form in \(app)\(title.isEmpty ? "" : " · \u{201C}\(title)\u{201D}") with \(fields.count) fields:"]
        for f in fields {
            var line = "\(f.id) \(f.kind.rawValue) \u{201C}\(f.label.isEmpty ? "(no label)" : f.label)\u{201D}"
            if f.required { line += " required" }
            if !f.placeholder.isEmpty, f.placeholder != f.label { line += " (hint \u{201C}\(f.placeholder)\u{201D})" }
            switch f.kind {
            case .secret: line += " — never filled by Jarvis"
            case .checkbox, .radio: line += " = \(f.value)"
            default: line += f.value.isEmpty ? " = empty" : " = \u{201C}\(f.value.prefix(60))\u{201D}"
            }
            if !f.options.isEmpty { line += " options: " + f.options.prefix(40).joined(separator: " | ") }
            lines.append(line)
        }
        let nav = Hearing.unique(buttons).prefix(12)
        if !nav.isEmpty { lines.append("Buttons: " + nav.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private static func scan(_ root: AXUIElement, browser: Bool) -> ([Field], [String: AXUIElement], [String], String) {
        var fields: [Field] = [], elements: [String: AXUIElement] = [:], buttons: [String] = []
        var lastText = "", visited = 0
        // Radio buttons in a row share the question written before the first of them.
        var radioGroup: String?
        let window = UIControl.attr(root, kAXFocusedWindowAttribute).flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let title = window.map { UIControl.str($0, kAXTitleAttribute) } ?? ""

        func label(_ el: AXUIElement, role: String) -> String {
            if let t = UIControl.attr(el, "AXTitleUIElement"), CFGetTypeID(t) == AXUIElementGetTypeID() {
                let v = UIControl.str(t as! AXUIElement, kAXValueAttribute)
                if !v.isEmpty { return v }
            }
            for key in [kAXTitleAttribute, kAXDescriptionAttribute] {
                let s = UIControl.str(el, key)
                if !s.isEmpty, !(role == "AXPopUpButton" && key == kAXTitleAttribute) { return s }
            }
            return lastText
        }

        func options(_ el: AXUIElement) -> [String] {
            var out: [String] = []
            func collect(_ e: AXUIElement, depth: Int) {
                guard depth < 4, out.count < 60 else { return }
                for c in UIControl.children(e) {
                    let r = UIControl.str(c, kAXRoleAttribute)
                    if r == "AXMenuItem" || r == "AXStaticText" {
                        let t = r == "AXMenuItem" ? UIControl.str(c, kAXTitleAttribute) : UIControl.str(c, kAXValueAttribute)
                        if !t.isEmpty { out.append(t) }
                    }
                    collect(c, depth: depth + 1)
                }
            }
            collect(el, depth: 0)
            return Hearing.unique(out)
        }

        func walk(_ el: AXUIElement, depth: Int, inPage: Bool) {
            guard depth < 70, visited < 15000, fields.count < 80 else { return }
            visited += 1
            let role = UIControl.str(el, kAXRoleAttribute)
            let page = inPage || role == "AXWebArea"
            // In a browser only the page counts, not the address bar or the browser's own search field.
            if browser, !page {
                for c in UIControl.children(el) { walk(c, depth: depth + 1, inPage: page) }
                return
            }
            if role == "AXStaticText" {
                let v = UIControl.str(el, kAXValueAttribute)
                if !v.isEmpty, v.count < 90, v != "*" { lastText = v }
            } else if role == "AXButton" {
                let t = UIControl.label(el)
                if !t.isEmpty, t.count < 40 { buttons.append(t) }
            } else if fieldRoles.contains(role) {
                let enabled = (UIControl.attr(el, kAXEnabledAttribute) as? Bool) != false
                if enabled, let f = UIControl.frame(el), f.width > 2, f.height > 2 {
                    let id = "f\(fields.count + 1)"
                    let secure = UIControl.str(el, kAXSubroleAttribute) == "AXSecureTextField"
                    var name = label(el, role: role)
                    let hint = UIControl.str(el, "AXPlaceholderValue")
                    if name.isEmpty { name = hint }
                    if role == "AXRadioButton" {
                        let choice = UIControl.str(el, kAXTitleAttribute)
                        if radioGroup == nil { radioGroup = lastText == choice ? "" : lastText }
                        let question = radioGroup ?? ""
                        name = question.isEmpty ? choice : "\(question): \(choice)"
                    } else {
                        radioGroup = nil
                        if !role.contains("Check") { lastText = "" }
                    }
                    var kind: Kind
                    switch role {
                    case "AXTextArea": kind = .multiline
                    case "AXPopUpButton": kind = .choice
                    case "AXCheckBox": kind = .checkbox
                    case "AXRadioButton": kind = .radio
                    case "AXDateField", "AXDateTimeArea": kind = .date
                    default: kind = .text
                    }
                    if secure || isSensitive(name) || isSensitive(hint) { kind = .secret }
                    let value: String
                    switch kind {
                    case .checkbox, .radio: value = (UIControl.attr(el, kAXValueAttribute) as? NSNumber)?.intValue == 1 ? "on" : "off"
                    case .secret: value = ""
                    case .choice: value = UIControl.str(el, kAXValueAttribute).isEmpty ? UIControl.str(el, kAXTitleAttribute) : UIControl.str(el, kAXValueAttribute)
                    default: value = UIControl.str(el, kAXValueAttribute)
                    }
                    let required = (UIControl.attr(el, "AXRequired") as? Bool) == true || name.hasSuffix("*")
                    let opts = kind == .choice || role == "AXComboBox" ? options(el) : []
                    fields.append(Field(id: id, kind: kind, label: name.trimmingCharacters(in: CharacterSet(charactersIn: " *:")),
                                        placeholder: hint, value: value, options: opts, required: required))
                    elements[id] = el
                }
                // A field's own children are its text or its options, not more fields.
                return
            }
            for c in UIControl.children(el) { walk(c, depth: depth + 1, inPage: page) }
        }
        if let window { walk(window, depth: 0, inPage: false) }
        return (fields, elements, buttons, title)
    }

    // MARK: Filling

    static func truthy(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.intValue != 0 }
        let s = (v as? String ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        return ["true", "yes", "on", "1", "checked", "agree", "y"].contains(s)
    }

    /// Fills the fields from the last reading. `values` maps field ids to text, an option, or true/false.
    /// Nothing is submitted.
    public static func fill(_ values: [String: Any]) async -> String {
        let (elements, fields, pid, appName, web) = cache.lock.withLock { (cache.elements, cache.fields, cache.pid, cache.app, cache.web) }
        guard !elements.isEmpty else { return "Read the form first (form read)." }
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return "\(appName) has closed." }
        let unknown = values.keys.filter { elements[$0] == nil }
        // Typing goes to the app in front, so bring the form's app forward first.
        app.activate()
        try? await Task.sleep(nanoseconds: 300_000_000)
        var filled: [String] = [], refused: [String] = [], failed: [String] = []
        for f in fields {
            guard let want = values[f.id], let el = elements[f.id] else { continue }
            if KillSwitch.shared.tripped { return "Stopped after filling \(filled.count) fields." }
            // Keystrokes go to whatever is in front: if the user switched away, stop rather than type into another app.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pid {
                return "Stopped after filling \(filled.count) field\(filled.count == 1 ? "" : "s"): \(appName) is no longer in front. Nothing was submitted."
            }
            let name = f.label.isEmpty ? f.id : f.label
            switch f.kind {
            case .secret:
                refused.append(name)
            case .checkbox, .radio:
                let on = truthy(want)
                if f.kind == .radio, !on { continue }
                let current = (UIControl.attr(el, kAXValueAttribute) as? NSNumber)?.intValue == 1
                if current != on { await press(el) }
                let now = (UIControl.attr(el, kAXValueAttribute) as? NSNumber)?.intValue == 1
                if now == on { filled.append(name) } else { failed.append(name) }
            case .choice:
                let text = (want as? String) ?? "\(want)"
                if let problem = await choose(el, text, pid: pid) { failed.append("\(name) (\(problem))") } else { filled.append(name) }
            case .text, .multiline, .date:
                var text = (want as? String) ?? "\(want)"
                if f.kind != .multiline { text = text.replacingOccurrences(of: "\n", with: " ") }
                if await put(el, text, web: web) { filled.append(name) } else { failed.append(name) }
            }
        }
        var out = filled.isEmpty ? "Filled nothing." : "Filled \(filled.count) field\(filled.count == 1 ? "" : "s"): " + filled.joined(separator: ", ") + "."
        if !refused.isEmpty { out += "\nLeft for the user (Jarvis never fills passwords, card details or codes): " + refused.joined(separator: ", ") + "." }
        if !failed.isEmpty { out += "\nCouldn't fill: " + failed.joined(separator: "; ") + "." }
        if !unknown.isEmpty { out += "\nNo such fields: " + unknown.sorted().joined(separator: ", ") + "." }
        let missing = fields.filter { f in
            f.required && f.kind != .secret && f.kind != .radio && values[f.id] == nil && f.value.isEmpty
        }.map { $0.label.isEmpty ? $0.id : $0.label }
        if !missing.isEmpty { out += "\nRequired and still empty: " + missing.joined(separator: ", ") + "." }
        return out + "\nNothing was submitted."
    }

    private static func press(_ el: AXUIElement) async {
        if AXUIElementPerformAction(el, kAXPressAction as CFString) != .success, let f = UIControl.frame(el) {
            await Input.click(at: CGPoint(x: f.midX, y: f.midY))
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
    }

    /// Puts text in a field. In web pages it's typed, as a person would, so the page notices the change.
    static func put(_ el: AXUIElement, _ text: String, web: Bool) async -> Bool {
        if !web, AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success,
           UIControl.str(el, kAXValueAttribute) == text.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(nanoseconds: 80_000_000)
        if (UIControl.attr(el, kAXFocusedAttribute) as? Bool) != true, let f = UIControl.frame(el) {
            await Input.click(at: CGPoint(x: f.midX, y: f.midY))
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        _ = await Input.key("cmd+a")
        if text.isEmpty {
            _ = await Input.key("delete")
            return true
        }
        await Input.type(text)
        try? await Task.sleep(nanoseconds: 80_000_000)
        let now = UIControl.str(el, kAXValueAttribute)
        if now.contains(text.prefix(12).trimmingCharacters(in: .whitespaces)) { return true }
        return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, text as CFString) == .success
    }

    /// The closest option to what was asked for: exact, then starting with it, then containing it.
    public static func bestOption(_ want: String, in options: [String]) -> String? {
        let w = want.lowercased().trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return nil }
        let lower = options.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        if let i = lower.firstIndex(of: w) { return options[i] }
        if let i = lower.firstIndex(where: { $0.hasPrefix(w) }) { return options[i] }
        if let i = lower.firstIndex(where: { $0.contains(w) }) { return options[i] }
        if let i = lower.firstIndex(where: { $0.count > 2 && w.contains($0) }) { return options[i] }
        return nil
    }

    /// Picks an option from a pop-up list; returns what went wrong, or nil when it worked.
    static func choose(_ el: AXUIElement, _ want: String, pid: pid_t) async -> String? {
        func current() -> String { (UIControl.str(el, kAXValueAttribute) + " " + UIControl.str(el, kAXTitleAttribute)).lowercased() }
        if current().contains(want.lowercased()) { return nil }
        await press(el)
        try? await Task.sleep(nanoseconds: 200_000_000)
        // The open list is either inside the control or a menu of the app.
        var items: [AXUIElement] = []
        func collect(_ e: AXUIElement, depth: Int) {
            guard depth < 5, items.count < 300 else { return }
            for c in UIControl.children(e) {
                if UIControl.str(c, kAXRoleAttribute) == "AXMenuItem" { items.append(c) }
                collect(c, depth: depth + 1)
            }
        }
        collect(el, depth: 0)
        if items.isEmpty {
            let root = AXUIElementCreateApplication(pid)
            for c in UIControl.children(root) where UIControl.str(c, kAXRoleAttribute) == "AXMenu" { collect(c, depth: 0) }
        }
        let titles = items.map { UIControl.str($0, kAXTitleAttribute) }
        if let pick = bestOption(want, in: titles), let i = titles.firstIndex(of: pick) {
            AXUIElementPerformAction(items[i], kAXPressAction as CFString)
            try? await Task.sleep(nanoseconds: 120_000_000)
            return nil
        }
        // No list to read: close it and type the option, the way a keyboard user picks from a list.
        _ = await Input.key("escape")
        AXUIElementSetAttributeValue(el, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        await Input.type(want)
        try? await Task.sleep(nanoseconds: 150_000_000)
        if current().contains(want.lowercased().prefix(4)) { return nil }
        return titles.isEmpty ? "no option like \u{201C}\(want)\u{201D}" : "no option like \u{201C}\(want)\u{201D}; options: " + titles.prefix(15).joined(separator: ", ")
    }

    // MARK: The user's details

    /// What forms usually ask for: the user's own card in Contacts, the details they saved in Jarvis, and their profile.
    public static func details(saved: String, settings s: JarvisSettings) -> String {
        var lines = meCard()
        if !s.userName.isEmpty { lines.append("Goes by: \(s.userName)") }
        if !s.aboutWork.isEmpty { lines.append("Work or study: \(s.aboutWork)") }
        if !s.aboutPlace.isEmpty { lines.append("Based in: \(s.aboutPlace)") }
        let extra = saved.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append("Saved details:\n" + extra) }
        guard !lines.isEmpty else {
            return "No details saved yet. Ask the user for what the form needs, and mention they can save them in Settings › Memory › Details for forms."
        }
        return lines.joined(separator: "\n")
    }

    /// The user's own card in Contacts, when Jarvis may read Contacts.
    static func meCard() -> [String] {
        guard People.status() == true else { return [] }
        let keys = [CNContactGivenNameKey, CNContactMiddleNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactJobTitleKey,
                    CNContactPhoneNumbersKey, CNContactEmailAddressesKey, CNContactPostalAddressesKey, CNContactBirthdayKey,
                    CNContactUrlAddressesKey, CNContactSocialProfilesKey] as [CNKeyDescriptor]
        guard let c = try? CNContactStore().unifiedMeContactWithKeys(toFetch: keys) else { return [] }
        func label(_ l: String?) -> String {
            guard let l, !l.isEmpty else { return "" }
            return " (" + CNLabeledValue<NSString>.localizedString(forLabel: l) + ")"
        }
        var out: [String] = []
        if !c.givenName.isEmpty { out.append("First name: \(c.givenName)") }
        if !c.middleName.isEmpty { out.append("Middle name: \(c.middleName)") }
        if !c.familyName.isEmpty { out.append("Last name: \(c.familyName)") }
        out += c.emailAddresses.prefix(3).map { "Email\(label($0.label)): \($0.value as String)" }
        out += c.phoneNumbers.prefix(3).map { "Phone\(label($0.label)): \($0.value.stringValue)" }
        for a in c.postalAddresses.prefix(2) {
            let v = a.value
            let parts = [v.street, v.city, v.state, v.postalCode, v.country].filter { !$0.isEmpty }
            if !parts.isEmpty { out.append("Address\(label(a.label)): " + parts.joined(separator: ", ")) }
        }
        if let b = c.birthday, let d = b.day, let m = b.month {
            out.append("Date of birth: " + (b.year.map { String(format: "%04d-%02d-%02d", $0, m, d) } ?? String(format: "%02d-%02d (year not saved)", m, d)))
        }
        if !c.organizationName.isEmpty { out.append("Organisation: \(c.organizationName)") }
        if !c.jobTitle.isEmpty { out.append("Job title: \(c.jobTitle)") }
        out += c.urlAddresses.prefix(4).map { "Website\(label($0.label)): \($0.value as String)" }
        out += c.socialProfiles.prefix(4).compactMap { p in
            let v = p.value
            let link = v.urlString.isEmpty ? v.username : v.urlString
            return link.isEmpty ? nil : "\(v.service.isEmpty ? "Profile" : v.service): \(link)"
        }
        return out
    }
}
