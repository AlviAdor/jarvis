import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

public struct Shot: Sendable {
    public let jpeg: Data
    public let width: Int
    public let height: Int
}

public enum Screen {
    /// Captures the main display, downscaled so each step stays cheap in tokens.
    public static func capture(maxDim: Int = 1280) throws -> Shot {
        let path = NSTemporaryDirectory() + "jarvis-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-C", "-m", "-t", "png", path]
        try p.run()
        p.waitUntilExit()

        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            throw LLMError.badResponse
        }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LLMError.badResponse
        }
        CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw LLMError.badResponse }
        return Shot(jpeg: out as Data, width: img.width, height: img.height)
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
