import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A file, image or clip the user adds to a request, ready to send to Gemini or Claude.
public struct Attachment: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case image, pdf, audio, video, text }

    public let id: UUID
    public let name: String
    public let kind: Kind
    public let mime: String
    public let data: Data        // the bytes sent inline (images, PDFs, audio, video)
    public let text: String?     // extracted text for documents and code
    public let thumbnail: Data?  // small JPEG for the chip, images only

    public static let maxInline = 15 * 1_000_000      // per file; Gemini allows about 20 MB per request in total
    public static let maxTotal = 18 * 1_000_000
    public static let maxText = 200_000

    public var size: Int { text?.utf8.count ?? data.count }
    public var sizeLabel: String { ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file) }
    /// Claude can't hear or watch; requests with these go to Gemini.
    public var needsGemini: Bool { kind == .audio || kind == .video }

    public var icon: String {
        switch kind {
        case .image: return "photo"
        case .pdf: return "doc.richtext"
        case .audio: return "waveform"
        case .video: return "film"
        case .text: return "doc.text"
        }
    }

    init(name: String, kind: Kind, mime: String, data: Data = Data(), text: String? = nil, thumbnail: Data? = nil) {
        self.id = UUID()
        self.name = name
        self.kind = kind
        self.mime = mime
        self.data = data
        self.text = text
        self.thumbnail = thumbnail
    }

    public enum LoadError: LocalizedError {
        case tooBig(String), unsupported(String), unreadable(String)
        public var errorDescription: String? {
            switch self {
            case .tooBig(let n): return "\(n) is too large to send (the limit is 15 MB per file)."
            case .unsupported(let n): return "Jarvis can't read \(n) yet. Images, PDFs, documents, code, audio and short videos work."
            case .unreadable(let n): return "Couldn't read \(n)."
            }
        }
    }

    static let audioTypes: [String: String] = ["mp3": "audio/mp3", "wav": "audio/wav", "m4a": "audio/aac", "aac": "audio/aac",
                                               "flac": "audio/flac", "ogg": "audio/ogg", "aiff": "audio/aiff", "aif": "audio/aiff"]
    static let videoTypes: [String: String] = ["mp4": "video/mp4", "mov": "video/mov", "m4v": "video/mp4", "webm": "video/webm",
                                               "mpeg": "video/mpeg", "avi": "video/avi"]

    /// Reads a file from disk into the right form for its type.
    public static func load(_ url: URL) throws -> Attachment {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0

        if type?.conforms(to: .image) == true {
            guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
            return try image(data, name: name)
        }
        if ext == "pdf" {
            guard bytes <= maxInline else { throw LoadError.tooBig(name) }
            guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
            return Attachment(name: name, kind: .pdf, mime: "application/pdf", data: data)
        }
        if let mime = audioTypes[ext] {
            guard bytes <= maxInline else { throw LoadError.tooBig(name) }
            guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
            return Attachment(name: name, kind: .audio, mime: mime, data: data)
        }
        if let mime = videoTypes[ext] {
            guard bytes <= maxInline else { throw LoadError.tooBig(name) }
            guard let data = try? Data(contentsOf: url) else { throw LoadError.unreadable(name) }
            return Attachment(name: name, kind: .video, mime: mime, data: data)
        }
        // Documents, code, data: send the words.
        let textual = type.map { $0.conforms(to: .text) || $0.conforms(to: .sourceCode) || $0.conforms(to: .json) || $0.conforms(to: .xml) } ?? false
        if textual || ["docx", "doc", "rtf", "rtfd", "odt", "html", "htm", "md", "csv", "tsv", "log", "yaml", "yml", "toml", "ipynb", "swift", "py", "js", "ts"].contains(ext) {
            guard let t = Files.text(of: url, limit: maxText), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LoadError.unreadable(name) }
            return Attachment(name: name, kind: .text, mime: "text/plain", text: t)
        }
        throw LoadError.unsupported(name)
    }

    /// Any image becomes a JPEG no larger than 2048 pixels, which every provider accepts.
    public static func image(_ data: Data, name: String) throws -> Attachment {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw LoadError.unreadable(name) }
        func jpeg(_ maxPixels: Int, quality: Double) -> Data? {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            let out = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
            CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            return CGImageDestinationFinalize(dest) ? out as Data : nil
        }
        guard let full = jpeg(2048, quality: 0.85) else { throw LoadError.unreadable(name) }
        let base = (name as NSString).deletingPathExtension
        return Attachment(name: base + ".jpg", kind: .image, mime: "image/jpeg", data: full, thumbnail: jpeg(96, quality: 0.7))
    }

    // MARK: Provider formats

    public var geminiPart: [String: Any] {
        if let text { return ["text": "Attached file \(name):\n```\n\(text)\n```"] }
        return ["inline_data": ["mime_type": mime, "data": data.base64EncodedString()]]
    }

    public var claudeBlock: [String: Any] {
        switch kind {
        case .image: return ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]]
        case .pdf: return ["type": "document", "source": ["type": "base64", "media_type": "application/pdf", "data": data.base64EncodedString()]]
        default: return ["type": "text", "text": "Attached file \(name):\n```\n\(text ?? "(this file type can't be read by this model)")\n```"]
        }
    }

    /// How the attachment is remembered in the conversation once it's been sent.
    public var mention: String { "[attached \(kind.rawValue): \(name)]" }
}
