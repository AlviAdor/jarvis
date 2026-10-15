import Foundation
import AppKit
import UserNotifications
import JarvisCore

/// Jarvis's macOS notifications, each with buttons that fit what it's about. Clicking one opens Jarvis.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = Notifier()

    enum Kind: String {
        case answer, timer, storage, battery, memory, thermal, general
        var category: String { "jarvis.\(rawValue)" }
    }

    /// What to do when the user clicks a notification or one of its buttons.
    var onAction: (@MainActor (_ action: String, _ info: [String: String], _ typed: String?) -> Void)?

    private var bundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    func register() {
        guard bundled else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        func button(_ id: String, _ title: String, icon: String, foreground: Bool = false) -> UNNotificationAction {
            UNNotificationAction(identifier: id, title: title, options: foreground ? [.foreground] : [], icon: UNNotificationActionIcon(systemImageName: icon))
        }
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  icon: UNNotificationActionIcon(systemImageName: "arrowshape.turn.up.left"),
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Ask Jarvis…")
        let open = button("open", "Open Jarvis", icon: "macwindow", foreground: true)
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Kind.answer.category, actions: [reply, button("copy", "Copy", icon: "doc.on.doc"), button("speak", "Read aloud", icon: "speaker.wave.2"), open], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.timer.category, actions: [button("snooze", "Snooze 5 minutes", icon: "zzz"), button("dismiss", "Done", icon: "checkmark")], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.storage.category, actions: [button("freeSpace", "Free up space", icon: "sparkles", foreground: true), button("storageReport", "What's using it?", icon: "internaldrive", foreground: true)], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.battery.category, actions: [button("batteryDrain", "What's draining it?", icon: "bolt.batteryblock", foreground: true), button("batterySettings", "Battery settings", icon: "gearshape")], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.memory.category, actions: [button("memoryHogs", "What's using memory?", icon: "memorychip", foreground: true), reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.thermal.category, actions: [button("cpuHogs", "What's heating it up?", icon: "thermometer.medium", foreground: true), reply], intentIdentifiers: []),
            UNNotificationCategory(identifier: Kind.general.category, actions: [reply, open], intentIdentifiers: []),
        ])
    }

    func post(_ kind: Kind, title: String, body: String, info: [String: String] = [:], after delay: TimeInterval? = nil) {
        guard bundled else { return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = kind.category
        c.threadIdentifier = kind.rawValue
        var i = info
        i["kind"] = kind.rawValue
        i["body"] = body
        c.userInfo = i
        let trigger = delay.map { UNTimeIntervalNotificationTrigger(timeInterval: max(1, $0), repeats: false) }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: trigger))
    }

    // Show banners even while Jarvis is the app in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        var info: [String: String] = [:]
        for (k, v) in response.notification.request.content.userInfo {
            if let k = k as? String, let v = v as? String { info[k] = v }
        }
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let action = response.actionIdentifier == UNNotificationDefaultActionIdentifier ? "open" : response.actionIdentifier
        let payload = info
        await MainActor.run { self.onAction?(action, payload, typed) }
    }
}
