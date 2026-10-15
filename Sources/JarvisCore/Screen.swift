import Foundation
import AppKit
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers
import ScreenCaptureKit

public struct Shot: @unchecked Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
    public var image: CGImage? = nil
}

public enum Screen {
    private static let asked = AskOnce()

    /// Captures the main display with ScreenCaptureKit, downscaled so each step stays cheap in tokens.
    /// Jarvis's own windows are left out of the picture.
    public static func capture(maxDim: Int = 1280) async throws -> Shot {
        guard CGPreflightScreenCaptureAccess() else {
            if asked.first("screen") { CGRequestScreenCaptureAccess() }
            throw LLMError.other("Jarvis needs Screen Recording permission. Turn on Jarvis in System Settings, Privacy and Security, Screen & System Audio Recording. If it already looks on, use Repair permissions in Jarvis's settings.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw LLMError.other("No display to capture.")
        }
        let mine = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: mine, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let w = Double(display.width), h = Double(display.height)
        let scale = min(1, Double(maxDim) / max(w, h))
        config.width = Int(w * scale)
        config.height = Int(h * scale)
        config.showsCursor = true
        config.capturesAudio = false
        let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LLMError.badResponse
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LLMError.badResponse }
        return Shot(jpeg: out as Data, width: img.width, height: img.height, image: img)
    }
}

/// Remembers which system prompts were already shown this session, so macOS isn't asked twice.
final class AskOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = Set<String>()
    func first(_ key: String) -> Bool { lock.withLock { done.insert(key).inserted } }
}

public enum Permissions {
    private static let asked = AskOnce()

    /// Prompts once per session if Accessibility (needed to move the mouse and type) hasn't been granted.
    public static func ensureAccessibility() throws {
        let prompt = asked.first("accessibility")
        let opts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            throw LLMError.other("Jarvis needs Accessibility permission to control the mouse and keyboard. Turn on Jarvis in System Settings, Privacy and Security, Accessibility. If it already looks on, use Repair permissions in Jarvis's settings.")
        }
    }
}

public final class KillSwitch: @unchecked Sendable {
    public static let shared = KillSwitch()
    private let lock = NSLock()
    private var flag = false

    public var tripped: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
    public func trip() { lock.lock(); flag = true; lock.unlock() }
    public func reset() { lock.lock(); flag = false; lock.unlock() }
}
