import Foundation
import Speech
import AVFoundation

/// Runs on the audio thread. Costs a few multiplications per buffer while idle, and only hands audio
/// to the speech recognizer once the room is loud enough to contain speech.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var preroll: [AVAudioPCMBuffer] = []
    private var loudRun = 0
    private var starting = false
    private var lastLoud = Date.distantPast
    private var began = Date()
    private var ended = false

    var threshold: Float = 0.02
    var suspended = false
    var onSpeechStart: (@Sendable () -> Void)?
    var onSilence: (@Sendable () -> Void)?

    static func rms(_ b: AVAudioPCMBuffer) -> Float {
        guard let ch = b.floatChannelData?[0] else { return 0 }
        let n = Int(b.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        var i = 0
        while i < n { sum += ch[i] * ch[i]; i += 4 }
        return (sum / Float((n + 3) / 4)).squareRoot()
    }

    func process(_ buffer: AVAudioPCMBuffer) {
        if suspended { return }
        let level = Self.rms(buffer)
        lock.lock()
        if let req = request {
            req.append(buffer)
            if level > threshold { lastLoud = Date() }
            let quiet = Date().timeIntervalSince(lastLoud) > 1.2
            let tooLong = Date().timeIntervalSince(began) > 25
            if (quiet || tooLong) && !ended {
                ended = true
                lock.unlock()
                onSilence?()
                return
            }
            lock.unlock()
            return
        }
        preroll.append(buffer)
        if preroll.count > 4 { preroll.removeFirst() }
        loudRun = level > threshold ? loudRun + 1 : 0
        let fire = loudRun >= 2 && !starting
        if fire { starting = true }
        lock.unlock()
        if fire { onSpeechStart?() }
    }

    func attach(_ req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        for b in preroll { req.append(b) }
        preroll.removeAll()
        request = req
        lastLoud = Date()
        began = Date()
        ended = false
        lock.unlock()
    }

    func detach() {
        lock.lock()
        request = nil
        starting = false
        loudRun = 0
        ended = false
        lock.unlock()
    }
}

@MainActor
public final class VoiceEngine: ObservableObject {
    @Published public private(set) var partial = ""
    @Published public private(set) var armed = false
    @Published public private(set) var running = false
    @Published public private(set) var hearing = false

    public var onCommand: ((String) -> Void)?
    public var wakeEnabled = true
    public var wakeWord = "jarvis"

    public var threshold: Float {
        get { gate.threshold }
        set { gate.threshold = newValue }
    }
    public var suspended: Bool {
        get { gate.suspended }
        set { gate.suspended = newValue }
    }

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private let gate = AudioGate()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var armTimeout: Task<Void, Never>?

    public init() {
        gate.onSpeechStart = { [weak self] in Task { @MainActor in self?.beginUtterance() } }
        gate.onSilence = { [weak self] in Task { @MainActor in self?.request?.endAudio() } }
        NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.restart() }
        }
    }

    public static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    public func start() throws {
        guard !running else { return }
        let input = engine.inputNode
        let gate = self.gate
        input.installTap(onBus: 0, bufferSize: 4096, format: input.outputFormat(forBus: 0)) { buffer, _ in
            gate.process(buffer)
        }
        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        gate.detach()
        running = false
        hearing = false
        armed = false
    }

    private func restart() {
        guard running else { return }
        stop()
        try? start()
    }

    /// Push-to-talk: treat the next utterance as a command, no wake word needed.
    public func arm() {
        armed = true
        armTimeout?.cancel()
        armTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { self?.armed = false }
        }
    }

    public func disarm() {
        armTimeout?.cancel()
        armed = false
    }

    private func beginUtterance() {
        guard running, request == nil, let recognizer, recognizer.isAvailable else { gate.detach(); return }
        // Ambient speech is ignored unless wake word listening is on or the user armed us.
        guard wakeEnabled || armed else { gate.detach(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        hearing = true
        gate.attach(req)

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in self?.update(text, final: final) }
        }
    }

    private func update(_ text: String?, final: Bool) {
        if let text, armed || containsWake(text) { partial = text }
        guard final else { return }
        let heard = text ?? partial
        request = nil
        task = nil
        hearing = false
        gate.detach()
        deliver(heard)
        partial = ""
    }

    private func containsWake(_ s: String) -> Bool {
        wakeRange(in: s) != nil
    }

    private func wakeRange(in s: String) -> Range<String.Index>? {
        let lower = s.lowercased()
        for w in [wakeWord.lowercased(), "jarvis", "jervis"] {
            if let r = lower.range(of: w) { return r }
        }
        return nil
    }

    private func deliver(_ heard: String) {
        let t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        if let r = wakeEnabled ? wakeRange(in: t) : nil {
            let rest = String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
            if rest.count >= 2 {
                disarm()
                onCommand?(rest)
            } else {
                arm()
            }
        } else if armed {
            disarm()
            onCommand?(t)
        }
    }
}

@MainActor
public final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    public var onSpeakingChange: ((Bool) -> Void)?

    public override init() {
        super.init()
        synth.delegate = self
    }

    public func say(_ text: String, rate: Double) {
        let u = AVSpeechUtterance(string: text)
        u.rate = Float(rate)
        onSpeakingChange?(true)
        synth.speak(u)
    }

    public func stop() {
        synth.stopSpeaking(at: .immediate)
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !self.synth.isSpeaking { self.onSpeakingChange?(false) }
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.onSpeakingChange?(false) }
    }
}
