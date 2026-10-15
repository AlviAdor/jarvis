import Foundation
import CoreGraphics

public enum Input {
    /// Stamped on every event Jarvis posts, so its own Esc presses don't trip the kill switch.
    public static let marker: Int64 = 0x4A52_5653

    private static func post(_ e: CGEvent?) {
        e?.setIntegerValueField(.eventSourceUserData, value: marker)
        e?.post(tap: .cghidEventTap)
    }

    /// Moves the real cursor along an eased path so the motion is visible.
    public static func move(to p: CGPoint, duration: Double = 0.35) async {
        let start = CGEvent(source: nil)?.location ?? p
        let steps = max(8, Int(duration * 60))
        for i in 1...steps {
            if KillSwitch.shared.tripped { return }
            let t = Double(i) / Double(steps)
            let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            let pt = CGPoint(x: start.x + (p.x - start.x) * e, y: start.y + (p.y - start.y) * e)
            post(CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: pt, mouseButton: .left))
            try? await Task.sleep(nanoseconds: UInt64(duration / Double(steps) * 1_000_000_000))
        }
    }

    public static func click(at p: CGPoint, right: Bool = false, count: Int = 1) async {
        await move(to: p)
        if KillSwitch.shared.tripped { return }
        let down: CGEventType = right ? .rightMouseDown : .leftMouseDown
        let up: CGEventType = right ? .rightMouseUp : .leftMouseUp
        let button: CGMouseButton = right ? .right : .left
        for n in 1...count {
            for type in [down, up] {
                let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
                e?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                post(e)
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
        }
    }

    public static func type(_ text: String) async {
        for ch in text {
            if KillSwitch.shared.tripped { return }
            let utf16 = Array(String(ch).utf16)
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down)
                e?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                post(e)
            }
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    public static func scroll(dy: Int, dx: Int = 0) {
        post(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0))
    }

    /// Presses at one point and releases at another, moving visibly in between.
    public static func drag(from a: CGPoint, to b: CGPoint) async {
        await move(to: a)
        if KillSwitch.shared.tripped { return }
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left))
        let steps = 24
        for i in 1...steps {
            if KillSwitch.shared.tripped { break }
            let t = CGFloat(i) / CGFloat(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left))
            try? await Task.sleep(nanoseconds: 12_000_000)
        }
        post(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left))
    }

    public static func button(down: Bool, at p: CGPoint) {
        post(CGEvent(mouseEventSource: nil, mouseType: down ? .leftMouseDown : .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    }

    private static let keyCodes: [String: CGKeyCode] = {
        var m: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
            "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35,
            "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
            "escape": 53, "esc": 53, "left": 123, "right": 124, "down": 125, "up": 126,
        ]
        m["-"] = 27; m["="] = 24; m["["] = 33; m["]"] = 30; m[","] = 43; m["."] = 47; m["/"] = 44
        return m
    }()

    /// Accepts combos such as "cmd+shift+t" or "return".
    public static func key(_ combo: String) async -> Bool {
        var flags: CGEventFlags = []
        var code: CGKeyCode?
        for part in combo.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: code = keyCodes[part]
            }
        }
        guard let code else { return false }
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            post(e)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        return true
    }
}
