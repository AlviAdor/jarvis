import XCTest
import AVFoundation
@testable import JarvisCore

/// Real speech from the Mac's own voices: a profile learned from one voice should accept that voice
/// and turn the others away. Skips when the voices aren't installed.
final class VoicePrintAudioTests: XCTestCase {
    private let lines = [
        "Jarvis, what's on my calendar today?",
        "The quick brown fox jumps over the lazy dog.",
        "Open Safari and search for the weather.",
        "I'd like a cup of coffee and some quiet music.",
        "Remind me to call home at six this evening.",
        "How much storage is left on my Mac right now?",
        "Please send a message to my sister about dinner.",
    ]

    private func speak(_ voice: String, _ text: String, to url: URL) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-v", voice, "-o", url.path, "--data-format=LEF32@48000", text]
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0 && FileManager.default.fileExists(atPath: url.path)
    }

    private func vector(_ url: URL) throws -> [Float]? {
        let file = try AVAudioFile(forReading: url)
        let f = VoiceFeatures()
        let format = file.processingFormat
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
            try file.read(into: buf, frameCount: 4096)
            if buf.frameLength == 0 { break }
            f.add(buf, loudEnough: AudioGate.rms(buf) > 0.005)
        }
        return f.vector()
    }

    func testProfileAcceptsItsVoiceAndRejectsOthers() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jarvis-voices-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let voices = ["Samantha", "Daniel", "Karen", "Fred"]
        var vecs: [String: [[Float]]] = [:]
        for v in voices {
            for (i, line) in lines.enumerated() {
                let url = dir.appendingPathComponent("\(v)-\(i).wav")
                guard speak(v, line, to: url) else { throw XCTSkip("The \(v) voice isn't installed.") }
                if let vec = try vector(url) { vecs[v, default: []].append(vec) }
            }
        }

        var accepted = 0, own = 0, falseAccepts = 0, others = 0
        for v in voices {
            let samples = vecs[v] ?? []
            XCTAssertEqual(samples.count, lines.count, "every line should give a vector")
            guard let profile = VoiceProfile.enroll(Array(samples.prefix(5))) else { return XCTFail("enrol \(v)") }
            for s in samples.suffix(2) { own += 1; if profile.matches(s, strictness: 0.5) { accepted += 1 } }
            for o in voices where o != v {
                for s in vecs[o] ?? [] { others += 1; if profile.matches(s, strictness: 0.5) { falseAccepts += 1 } }
            }
        }
        print("voiceprint: accepted \(accepted)/\(own) own, \(falseAccepts)/\(others) others")
        XCTAssertGreaterThanOrEqual(Double(accepted) / Double(own), 0.75)
        XCTAssertLessThanOrEqual(Double(falseAccepts) / Double(others), 0.08)
    }
}
