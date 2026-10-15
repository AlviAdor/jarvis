import Foundation
import Accelerate
import AVFoundation

/// A compact voiceprint built from mel-frequency cepstral coefficients (MFCCs), the classic features
/// for telling speakers apart: the shape of someone's vocal tract shows up in the spectral envelope,
/// and dropping the first coefficient removes loudness. Statistics are taken over voiced frames only.
/// It is a convenience filter that makes Jarvis ignore other voices and the TV, not a security check;
/// a recording of you, or a very similar voice, can pass it.
final class VoiceFeatures {
    static let mels = 40
    static let ceps = 19
    static let dims = ceps * 3   // means, spreads and the spread of how fast they change

    private let n = 1024
    private let log2n: vDSP_Length = 10
    private let setup: FFTSetup
    private var window: [Float]
    private var carry: [Float] = []
    private var frames: [(energy: Float, c: [Float])] = []
    private var bank: [[(Int, Float)]] = []
    private var dct: [[Float]] = []
    private let lifter: [Float]
    private var sampleRate: Double = 0

    init() {
        setup = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: 1024)
        vDSP_hann_window(&window, 1024, Int32(vDSP_HANN_NORM))
        let L: Float = 22
        lifter = (1...Self.ceps).map { 1 + (L / 2) * sin(Float.pi * Float($0) / L) }
        dct = (1...Self.ceps).map { k in
            (0..<Self.mels).map { m in cos(Float.pi * Float(k) * (Float(m) + 0.5) / Float(Self.mels)) }
        }
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func reset() {
        carry.removeAll()
        frames.removeAll()
    }

    /// Triangular filters spaced evenly on the mel scale between 80 Hz and 7.6 kHz.
    private func makeBank(_ sr: Double) {
        sampleRate = sr
        func mel(_ f: Double) -> Double { 2595 * log10(1 + f / 700) }
        func hz(_ m: Double) -> Double { 700 * (pow(10, m / 2595) - 1) }
        let lo = mel(80), hi = mel(min(7600, sr / 2 - 1))
        let points = (0...(Self.mels + 1)).map { i -> Int in
            let f = hz(lo + (hi - lo) * Double(i) / Double(Self.mels + 1))
            return min(n / 2 - 1, max(1, Int((f * Double(n) / sr).rounded())))
        }
        bank = (0..<Self.mels).map { m in
            let a = points[m], b = max(points[m + 1], a + 1), c = max(points[m + 2], b + 1)
            var w: [(Int, Float)] = []
            for k in a..<b { w.append((k, Float(k - a) / Float(b - a))) }
            for k in b..<min(c, n / 2) { w.append((k, Float(c - k) / Float(c - b))) }
            return w
        }
    }

    func add(_ buffer: AVAudioPCMBuffer, loudEnough: Bool) {
        guard loudEnough, let ch = buffer.floatChannelData?[0] else { carry.removeAll(); return }
        if sampleRate != buffer.format.sampleRate { makeBank(buffer.format.sampleRate) }
        carry.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(buffer.frameLength)))
        while carry.count >= n {
            frames.append(cepstrum(Array(carry[0..<n])))
            carry.removeFirst(n)
            if frames.count > 600 { break }
        }
    }

    private func cepstrum(_ x: [Float]) -> (Float, [Float]) {
        var w = [Float](repeating: 0, count: n)
        vDSP_vmul(x, 1, window, 1, &w, 1, vDSP_Length(n))
        var re = [Float](repeating: 0, count: n / 2)
        var im = [Float](repeating: 0, count: n / 2)
        var power = [Float](repeating: 0, count: n / 2)
        re.withUnsafeMutableBufferPointer { rp in
            im.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                w.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(n / 2))
            }
        }
        let logMel: [Float] = bank.map { filter in
            var e: Float = 0
            for (k, wt) in filter { e += power[k] * wt }
            return log(e + 1e-10)
        }
        var total: Float = 0
        vDSP_sve(power, 1, &total, vDSP_Length(n / 2))
        let c = (0..<Self.ceps).map { k -> Float in
            var sum: Float = 0
            vDSP_dotpr(dct[k], 1, logMel, 1, &sum, vDSP_Length(Self.mels))
            return sum * lifter[k]
        }
        return (log10(total + 1e-10), c)
    }

    /// Means and spreads of the voiced frames, or nil if there wasn't enough speech.
    func vector() -> [Float]? {
        guard let peak = frames.map(\.energy).max() else { return nil }
        let voiced = frames.filter { $0.energy >= peak - 2.5 }.map(\.c)   // within 25 dB of the loudest frame
        guard voiced.count >= 8 else { return nil }
        let d = Self.ceps
        func stats(_ rows: [[Float]]) -> (mean: [Float], sd: [Float]) {
            var mean = [Float](repeating: 0, count: d)
            for r in rows { for i in 0..<d { mean[i] += r[i] } }
            mean = mean.map { $0 / Float(rows.count) }
            var sd = [Float](repeating: 0, count: d)
            for r in rows { for i in 0..<d { sd[i] += (r[i] - mean[i]) * (r[i] - mean[i]) } }
            return (mean, sd.map { ($0 / Float(rows.count)).squareRoot() })
        }
        let base = stats(voiced)
        let deltas: [[Float]] = (1..<(voiced.count - 1)).map { t in (0..<d).map { (voiced[t + 1][$0] - voiced[t - 1][$0]) / 2 } }
        // Spreads are always positive and alike for everyone; their log shape, centred, is what differs.
        func shape(_ v: [Float]) -> [Float] {
            let l = v.map { log($0 + 1e-3) }
            let m = l.reduce(0, +) / Float(l.count)
            return l.map { ($0 - m) * 4 }
        }
        let mean = base.mean.map { $0 / 4 }
        return mean + shape(base.sd) + shape(stats(deltas).sd)
    }
}

public struct VoiceProfile: Codable, Equatable {
    public var center: [Float]
    public var floor: Float          // the lowest score the user's own voice is expected to reach
    public var samples: [[Float]]    // every learned sample, newest last

    public static let maxSamples = 40

    public init(center: [Float], floor: Float, samples: [[Float]] = []) {
        self.center = center
        self.floor = floor
        self.samples = samples
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        center = try c.decode([Float].self, forKey: .center)
        floor = try c.decode(Float.self, forKey: .floor)
        samples = try c.decodeIfPresent([[Float]].self, forKey: .samples) ?? []
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / ((na.squareRoot() * nb.squareRoot()) + 1e-9)
    }

    static func average(_ s: [[Float]]) -> [Float] {
        guard let dim = s.first?.count else { return [] }
        return (0..<dim).map { i in s.reduce(0) { $0 + $1[i] } / Float(s.count) }
    }

    /// How much `v` sounds like the user: half the match to their average voice, half the match to the
    /// three samples it's closest to, so natural variety in how they speak still counts.
    static func score(_ v: [Float], center: [Float], samples: [[Float]]) -> Float {
        let c = cosine(v, center)
        guard samples.count >= 3 else { return c }
        let near = samples.map { cosine(v, $0) }.sorted(by: >).prefix(3)
        return 0.5 * c + 0.5 * near.reduce(0, +) / Float(near.count)
    }

    public func score(_ v: [Float]) -> Float { Self.score(v, center: center, samples: samples) }

    /// Where the user's own voice sits: each sample scored against all the others, then a margin below
    /// the typical score that still covers their quieter or hoarser moments.
    static func calibrate(_ samples: [[Float]]) -> Float {
        let loo: [Float] = samples.indices.map { i in
            var others = samples
            others.remove(at: i)
            return score(samples[i], center: average(others), samples: others)
        }
        let mean = loo.reduce(0, +) / Float(loo.count)
        let sd = (loo.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Float(loo.count)).squareRoot()
        return min(loo.min() ?? mean, mean - 1.5 * sd)
    }

    /// Needs at least 3 samples.
    public static func enroll(_ samples: [[Float]]) -> VoiceProfile? {
        guard samples.count >= 3, samples.allSatisfy({ $0.count == samples[0].count }) else { return nil }
        let kept = Array(samples.suffix(maxSamples))
        return VoiceProfile(center: average(kept), floor: calibrate(kept), samples: kept)
    }

    /// The score needed to pass. strictness 0...1: higher demands a closer match.
    public func threshold(strictness: Double) -> Float {
        floor - Float(0.10 * (1 - strictness)) - 0.02
    }

    public func matches(_ v: [Float], strictness: Double) -> Bool {
        score(v) >= threshold(strictness: strictness)
    }

    /// Adds a sample the user confirmed was them, so the profile keeps up with their mic, room and mood.
    public mutating func learn(_ v: [Float]) {
        guard v.count == center.count else { return }
        samples.append(v)
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
        guard samples.count >= 3 else { return }
        center = Self.average(samples)
        floor = Self.calibrate(samples)
    }

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiceprint.json")
    }

    /// A profile from an older version of the voiceprint can't be compared, so it's dropped.
    public static func load() -> VoiceProfile? {
        guard let p = (try? Data(contentsOf: url)).flatMap({ try? JSONDecoder().decode(VoiceProfile.self, from: $0) }) else { return nil }
        return p.center.count == VoiceFeatures.dims ? p : nil
    }

    public func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url, options: [.atomic, .completeFileProtection]) }
    }

    public static func delete() { try? FileManager.default.removeItem(at: url) }
}

public struct VoiceOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let language: String
    public let quality: String
}

public enum VoiceCatalog {
    /// Asks to use the Personal Voice the user recorded on this Mac (Accessibility, Personal Voice).
    public static func requestPersonalVoice() async -> Bool {
        await withCheckedContinuation { c in
            AVSpeechSynthesizer.requestPersonalVoiceAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// Installed voices, best quality first. More can be downloaded in System Settings, Accessibility, Spoken Content.
    public static func all() -> [VoiceOption] {
        AVSpeechSynthesisVoice.speechVoices().map { v in
            let q: String
            if v.voiceTraits.contains(.isPersonalVoice) {
                q = "Personal"
            } else {
                switch v.quality {
                case .premium: q = "Premium"
                case .enhanced: q = "Enhanced"
                default: q = "Standard"
                }
            }
            return VoiceOption(id: v.identifier, name: v.name, language: v.language, quality: q)
        }
        .sorted { a, b in
            let order = ["Personal": 0, "Premium": 1, "Enhanced": 2, "Standard": 3]
            if order[a.quality]! != order[b.quality]! { return order[a.quality]! < order[b.quality]! }
            return (a.language, a.name) < (b.language, b.name)
        }
    }
}
