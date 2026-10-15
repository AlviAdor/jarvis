import Foundation
import AppKit
import AVFoundation
import Speech
import ApplicationServices

public enum Links {
    public static let geminiKey = URL(string: "https://aistudio.google.com/apikey")!
    public static let geminiTerms = URL(string: "https://ai.google.dev/gemini-api/terms")!
    public static let googleUsePolicy = URL(string: "https://policies.google.com/terms/generative-ai/use-policy")!
    public static let claudeConsole = URL(string: "https://platform.claude.com/")!
    public static let claudeUsePolicy = URL(string: "https://www.anthropic.com/legal/aup")!
    public static let spokenContent = URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?Spoken")!
}

public enum Terms {
    /// Bump when the text changes; everyone is asked to accept again.
    public static let version = "1.0"

    public static let text = """
    JARVIS TERMS OF USE AND DISCLAIMER (version \(version))

    Please read this before using Jarvis. By accepting, you agree to it.

    1. WHAT JARVIS IS
    Jarvis is software that lets AI models you choose (Google Gemini, and optionally Anthropic Claude) listen to you, look at your screen, and operate your Mac, including the mouse, keyboard, apps, files and email, when you ask. It is made by an individual developer ("the Developer") and is not affiliated with, endorsed by, or sponsored by Google or Anthropic.

    2. YOU ARE RESPONSIBLE
    You are solely responsible for what you ask Jarvis to do and for everything Jarvis does on your Mac and in your accounts. AI models make mistakes, misread screens, and can be tricked by text on a web page, in an email or in a document. Watch what Jarvis does, keep confirmations switched on, and press Esc to stop it at any time. Do not use Jarvis for anything where an error could cause serious harm or loss.

    3. NO WARRANTY
    Jarvis is provided "as is" and "as available", without warranty of any kind, express or implied, including fitness for a particular purpose, accuracy, reliability, security or non-infringement.

    4. NO LIABILITY
    To the maximum extent permitted by law, the Developer is not responsible or liable for any loss or damage of any kind arising from your use of Jarvis, including lost or deleted data, emails or messages sent, purchases made, changes to settings or files, account suspension, API charges, security incidents, or any indirect or consequential loss. Nothing in these terms excludes liability that cannot be excluded by law. You agree to hold the Developer harmless from claims arising from your use of Jarvis, to the extent the law allows.

    5. GOOGLE AND ANTHROPIC POLICIES
    Jarvis sends what you say and type, and screenshots when you ask it to operate your screen, to the AI providers whose keys you add. You must follow their rules:
    - Google: the Gemini API Additional Terms of Service and the Generative AI Prohibited Use Policy. You must be 18 or older to use the Gemini API.
    - Anthropic: the Usage Policy (Acceptable Use Policy) and Anthropic's terms of service.
    Jarvis is designed to be used within these policies, but compliance is your responsibility. Do not use Jarvis for anything those policies prohibit. You pay any charges on your own API keys; a chat subscription such as Claude Pro or Gemini Plus does not include API access.

    6. YOUR DATA
    Speech is recognized on your Mac when the on-device model is available. Text, screenshots and tool results are sent to the providers you configure and are handled under their terms. Your screen may show private information: do not use Jarvis around data you are not allowed to share. Jarvis has no analytics and the Developer does not receive your data. Keys are stored in your macOS Keychain.

    7. VOICE MATCH
    The optional voice match is an experimental convenience filter. It is not a security feature and can be fooled.

    8. LAWFUL USE
    Use Jarvis only on devices and accounts you own or are authorised to control, and only for lawful purposes.

    9. CHANGES
    If these terms change, Jarvis will ask you to accept the new version.
    """
}

public struct PermissionItem: Identifiable, Sendable {
    public enum Kind: String, Sendable { case microphone, speech, accessibility, screen, calendar, reminders, contacts, automation, fullDisk }
    public let id: Kind
    public let title: String
    public let why: String
    public let granted: Bool?   // nil when macOS can't tell us or hasn't asked yet
    public let optional: Bool
}

public extension Permissions {
    static func status() -> [PermissionItem] {
        [
            PermissionItem(id: .microphone, title: "Microphone", why: "Hear the wake word and your requests.",
                           granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized, optional: false),
            PermissionItem(id: .speech, title: "Speech Recognition", why: "Turn your voice into text on this Mac.",
                           granted: SFSpeechRecognizer.authorizationStatus() == .authorized, optional: false),
            PermissionItem(id: .accessibility, title: "Accessibility", why: "Move the mouse, type for you, and let Esc stop Jarvis anywhere.",
                           granted: AXIsProcessTrusted(), optional: false),
            PermissionItem(id: .screen, title: "Screen Recording", why: "See your screen when you ask Jarvis to work on it.",
                           granted: CGPreflightScreenCaptureAccess(), optional: false),
            PermissionItem(id: .calendar, title: "Calendars", why: "Read and add events when you ask.",
                           granted: Agenda.status(.event), optional: true),
            PermissionItem(id: .reminders, title: "Reminders", why: "Read and add reminders when you ask.",
                           granted: Agenda.status(.reminder), optional: true),
            PermissionItem(id: .contacts, title: "Contacts", why: "Find someone's number or email by name.",
                           granted: People.status(), optional: true),
            PermissionItem(id: .automation, title: "Automation", why: "Control Mail, Notes, Messages, Music and Finder. macOS asks per app the first time.",
                           granted: nil, optional: true),
            PermissionItem(id: .fullDisk, title: "Full Disk Access", why: "Lets disk cleanup measure the Trash, Mail attachments and iPhone backups.",
                           granted: hasFullDiskAccess(), optional: true),
        ]
    }

    /// Reading another app's protected data succeeds only with Full Disk Access. Nothing is read.
    static func hasFullDiskAccess() -> Bool {
        let probe = NSHomeDirectory() + "/Library/Containers/com.apple.stocks"
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno == ENOENT ? FileManager.default.isReadableFile(atPath: NSHomeDirectory() + "/Library/Safari") : false
    }

    @MainActor
    static func request(_ kind: PermissionItem.Kind) async {
        switch kind {
        case .microphone, .speech: _ = await VoiceEngine.authorize()
        case .accessibility: _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        case .screen:
            if !CGRequestScreenCaptureAccess() { openSettings(kind) }
        case .calendar: _ = await Agenda.access(.event)
        case .reminders: _ = await Agenda.access(.reminder)
        case .contacts: _ = await People.search("")
        case .automation, .fullDisk: openSettings(kind)
        }
    }

    @MainActor
    static func openSettings(_ kind: PermissionItem.Kind) {
        let pane: String
        switch kind {
        case .microphone: pane = "Privacy_Microphone"
        case .speech: pane = "Privacy_SpeechRecognition"
        case .accessibility: pane = "Privacy_Accessibility"
        case .screen: pane = "Privacy_ScreenCapture"
        case .calendar: pane = "Privacy_Calendars"
        case .reminders: pane = "Privacy_Reminders"
        case .contacts: pane = "Privacy_Contacts"
        case .automation: pane = "Privacy_Automation"
        case .fullDisk: pane = "Privacy_AllFiles"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }

    /// Clears every permission macOS has stored for Jarvis, including stale ones left by older builds,
    /// so the next request starts clean. The app relaunches afterwards.
    static func reset() async -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let out = await Run.capture("/usr/bin/tccutil", ["reset", "All", id], timeout: 10)
        return !out.lowercased().contains("failed")
    }
}
