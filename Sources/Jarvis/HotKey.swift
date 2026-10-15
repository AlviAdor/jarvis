import Carbon

/// System-wide shortcut to talk to Jarvis from any app. Carbon hot keys need no extra permission.
final class HotKey {
    static var action: (() -> Void)?
    static let labels: [(id: String, label: String)] = [
        ("option+space", "⌥ Space"), ("control+space", "⌃ Space"), ("command+shift+j", "⌘ ⇧ J"), ("off", "Off"),
    ]

    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var current = ""

    func set(_ combo: String) {
        guard combo != current else { return }
        current = combo
        if let ref {
            UnregisterEventHotKey(ref)
            self.ref = nil
        }
        guard let (code, mods) = Self.parse(combo) else { return }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4A52_5653), id: 1)   // "JRVS"
        RegisterEventHotKey(code, mods, id, GetApplicationEventTarget(), 0, &ref)
    }

    static func parse(_ combo: String) -> (UInt32, UInt32)? {
        switch combo {
        case "option+space": return (UInt32(kVK_Space), UInt32(optionKey))
        case "control+space": return (UInt32(kVK_Space), UInt32(controlKey))
        case "command+shift+j": return (UInt32(kVK_ANSI_J), UInt32(cmdKey | shiftKey))
        default: return nil
        }
    }

    static func label(_ combo: String) -> String {
        labels.first { $0.id == combo }?.label ?? combo
    }
}
