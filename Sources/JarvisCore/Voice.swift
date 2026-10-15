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

    private let features = VoiceFeatures()
    private(set) var latestLevel: Float = 0
    /// Slow-moving estimate of the room's background level, so a fan or air conditioning never counts as speech.
    private var noiseFloor: Float = 0.004

    var threshold: Float = 0.02
    var pause: TimeInterval = 1.0
    /// Extra patience while the sentence sounds unfinished ("…and", "because…").
    var extraPause: TimeInterval = 0
    /// Jarvis is talking. With `bargeIn`, the mic still listens for the user talking over it.
    var suspended = false {
        didSet { if suspended && !oldValue { echo = 0; bargeRun = 0; speakingSince = Date() } }
    }
    var bargeIn = true
    var onSpeechStart: (@Sendable () -> Void)?
    var onSilence: (@Sendable () -> Void)?
    var onBargeIn: (@Sendable () -> Void)?
    /// How loud Jarvis's own voice is in the mic, learned while it speaks.
    private var echo: Float = 0
    private var bargeRun = 0
    private var speakingSince = Date()

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
        if suspended {
            guard bargeIn else { return }
            listenOverSpeech(buffer)
            return
        }
        let level = Self.rms(buffer)
        lock.lock()
        if let req = request {
            req.append(buffer)
            latestLevel = level
            features.add(buffer, loudEnough: level > threshold)
            if level > threshold { lastLoud = Date() }
            let quiet = Date().timeIntervalSince(lastLoud) > pause + extraPause
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
        // Follow quiet periods quickly and loud ones slowly, so speech barely moves the floor.
        noiseFloor += (level - noiseFloor) * (level < noiseFloor ? 0.2 : 0.005)
        let trigger = max(threshold, noiseFloor * 3)
        loudRun = level > trigger ? loudRun + 1 : 0
        let fire = loudRun >= 2 && !starting
        if fire { starting = true }
        lock.unlock()
        if fire { onSpeechStart?() }
    }

    /// While Jarvis talks: learn how its own voice sounds in the mic for the first moment, then treat
    /// a quarter second of clearly louder sound as the user talking over it.
    private func listenOverSpeech(_ buffer: AVAudioPCMBuffer) {
        let level = Self.rms(buffer)
        lock.lock()
        preroll.append(buffer)
        if preroll.count > 6 { preroll.removeFirst() }
        let warm = Date().timeIntervalSince(speakingSince) > 0.4
        let trigger = max(threshold * 1.8, echo * 2.0, noiseFloor * 5)
        if !warm || level <= trigger {
            echo += (level - echo) * (level > echo ? 0.35 : 0.02)
        }
        bargeRun = warm && level > trigger ? bargeRun + 1 : 0
        let fire = bargeRun >= 3
        if fire { bargeRun = 0 }
        lock.unlock()
        if fire { onBargeIn?() }
    }

    func takeVector() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return features.vector()
    }

    func attach(_ req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        features.reset()
        for b in preroll { req.append(b) }
        preroll.removeAll()
        request = req
        lastLoud = Date()
        began = Date()
        ended = false
        extraPause = 0
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
    @Published public private(set) var level: Float = 0
    @Published public private(set) var enrollProgress: Int?   // samples captured so far while enrolling
    /// Waiting for the user's spoken answer to a question (the getting-to-know-you chat). No wake word needed.
    @Published public private(set) var capturing = false
    /// The answer and the voiceprint of how it was said.
    public var onAnswer: ((String, [Float]?) -> Void)?
    @Published public private(set) var profile: VoiceProfile? = VoiceProfile.load()

    public var onCommand: ((String) -> Void)?
    public var onRejected: (() -> Void)?
    public var onEnrolled: ((Bool) -> Void)?
    public var lockEnabled = false
    public var lockStrictness = 0.5
    public static let enrollTarget = 5
    private var enrollSamples: [[Float]] = []
    private var pushArmed = false
    private var levelTimer: Timer?
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
    /// Lets the user interrupt Jarvis by talking over it.
    public var bargeInEnabled: Bool {
        get { gate.bargeIn }
        set { gate.bargeIn = newValue }
    }
    public var onBargeIn: (() -> Void)?

    /// Sentences that stop on a word like "and" or "because" aren't finished yet.
    nonisolated public static func soundsUnfinished(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if t.hasSuffix(",") || t.hasSuffix("-") { return true }
        guard let last = t.split(separator: " ").last.map({ String($0).trimmingCharacters(in: .punctuationCharacters) }) else { return false }
        return ["and", "or", "but", "so", "because", "cause", "the", "a", "an", "to", "with", "for", "of", "about", "my", "your",
                "is", "are", "was", "if", "that", "then", "um", "uh", "erm", "like", "in", "on", "at", "from", "into", "which",
                "who", "when", "where", "what", "how", "also", "plus", "than", "as", "it's", "i'm", "and then", "maybe", "please"].contains(last)
    }

    public var pause: TimeInterval {
        get { gate.pause }
        set { gate.pause = newValue }
    }
    public var onSpeechStart: (() -> Void)?
    /// The wake word was just heard in a sentence that's still going.
    public var onWakeHeard: (() -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private let gate = AudioGate()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var armTimeout: Task<Void, Never>?

    public init() {
        gate.onSpeechStart = { [weak self] in Task { @MainActor in self?.beginUtterance() } }
        gate.onSilence = { [weak self] in Task { @MainActor in self?.request?.endAudio() } }
        gate.onBargeIn = { [weak self] in Task { @MainActor in self?.onBargeIn?() } }
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
    public func arm(push: Bool = false) {
        armed = true
        pushArmed = push
        armTimeout?.cancel()
        armTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            if !Task.isCancelled { self?.armed = false }
        }
    }

    public func disarm() {
        armTimeout?.cancel()
        armed = false
        pushArmed = false
    }

    // MARK: Voice match

    public func startEnrollment() {
        enrollSamples = []
        enrollProgress = 0
    }

    public func cancelEnrollment() {
        enrollProgress = nil
        enrollSamples = []
    }

    /// Listens for one answer. Ends after the user pauses, or after `timeout` seconds of silence.
    public func captureAnswer(timeout: TimeInterval = 15) {
        capturing = true
        partial = ""
        armTimeout?.cancel()
        armTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            guard !Task.isCancelled, let self, self.capturing, self.request == nil else { return }
            self.capturing = false
            self.onAnswer?("", nil)
        }
    }

    public func stopCapture() {
        capturing = false
        armTimeout?.cancel()
    }

    /// Uses a voiceprint learned elsewhere, such as from the getting-to-know-you chat.
    public func adopt(_ p: VoiceProfile) {
        p.save()
        profile = p
    }

    public func removeProfile() {
        VoiceProfile.delete()
        profile = nil
    }

    private func passesLock(_ v: [Float]?) -> Bool {
        guard lockEnabled, let profile, !pushArmed else { return true }
        guard let v else { return false }
        return profile.matches(v, strictness: lockStrictness)
    }

    private func beginUtterance() {
        guard running, request == nil, let recognizer, recognizer.isAvailable else { gate.detach(); return }
        // Ambient speech is ignored unless wake word listening is on or the user armed us.
        guard wakeEnabled || armed || enrollProgress != nil || capturing else { gate.detach(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        hearing = true
        onSpeechStart?()
        gate.attach(req)
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                // Only animate for speech meant for Jarvis; background talk and the TV leave the UI alone.
                guard self.armed || self.capturing || !self.partial.isEmpty || self.enrollProgress != nil else { return }
                self.level = min(1, self.gate.latestLevel * 8)
            }
        }

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in self?.update(text, final: final) }
        }
    }

    private func update(_ text: String?, final: Bool) {
        if let text, armed || capturing || containsWake(text) || enrollProgress != nil {
            if partial.isEmpty, !armed, !capturing, enrollProgress == nil { onWakeHeard?() }
            partial = text
            gate.extraPause = Self.soundsUnfinished(text) ? 1.6 : 0
        }
        guard final else { return }
        let heard = text ?? partial
        request = nil
        task = nil
        hearing = false
        levelTimer?.invalidate()
        level = 0
        let vector = gate.takeVector()
        gate.detach()
        if capturing {
            capturing = false
            armTimeout?.cancel()
            onAnswer?(heard.trimmingCharacters(in: .whitespacesAndNewlines), vector)
        } else if enrollProgress != nil {
            collect(vector, heard: heard)
        } else if passesLock(vector) {
            deliver(heard)
        } else if containsWake(heard) || armed {
            onRejected?()
        }
        partial = ""
    }

    private func collect(_ v: [Float]?, heard: String) {
        guard let v, heard.split(separator: " ").count >= 2 else { return }   // needs a real phrase
        enrollSamples.append(v)
        enrollProgress = enrollSamples.count
        if enrollSamples.count >= Self.enrollTarget {
            let p = VoiceProfile.enroll(enrollSamples)
            p?.save()
            profile = p
            enrollProgress = nil
            enrollSamples = []
            onEnrolled?(p != nil)
        }
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
public final class Speaker: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var player: AVAudioPlayer?
    private var fetch: Task<Void, Never>?
    public var onSpeakingChange: ((Bool) -> Void)?
    /// Called with a reason when the Gemini voice can't be used and the Mac voice takes over.
    public var onFallback: ((String) -> Void)?
    public var geminiKey: () -> String = { "" }

    public var isSpeaking: Bool { synth.isSpeaking || (player?.isPlaying ?? false) || fetch != nil }

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks with the voice chosen in settings. The Gemini voice falls back to the Mac's voice on any error.
    public func say(_ text: String, settings s: JarvisSettings, queue: Bool = true) {
        if s.voiceEngine == "gemini", !geminiKey().isEmpty {
            sayGemini(text, s)
        } else {
            sayLocal(text, settings: s, queue: queue)
        }
    }

    /// Always the Mac's own voice: instant, offline, used for streamed sentences and short step narration.
    public func sayLocal(_ text: String, settings s: JarvisSettings, queue: Bool = true) {
        if !queue { stop() }
        let u = AVSpeechUtterance(string: text)
        u.rate = Float(s.voiceRate)
        u.pitchMultiplier = Float(s.voicePitch)
        u.volume = Float(s.voiceVolume)
        if !s.voiceID.isEmpty, let v = AVSpeechSynthesisVoice(identifier: s.voiceID) { u.voice = v }
        onSpeakingChange?(true)
        synth.speak(u)
    }

    private func sayGemini(_ text: String, _ s: JarvisSettings) {
        stop()
        onSpeakingChange?(true)
        let key = geminiKey()
        fetch = Task { [weak self] in
            do {
                let wav = try await GeminiVoice.synthesize(text, voice: s.geminiVoice, style: s.voiceStyle, model: s.ttsModel, key: key)
                guard let self, !Task.isCancelled else { return }
                self.fetch = nil
                let p = try AVAudioPlayer(data: wav)
                p.delegate = self
                p.volume = Float(s.voiceVolume)
                self.player = p
                p.play()
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.fetch = nil
                self.onFallback?(Friendly.message(error))
                self.sayLocal(text, settings: s, queue: false)
            }
        }
    }

    public func stop() {
        fetch?.cancel()
        fetch = nil
        player?.stop()
        player = nil
        synth.stopSpeaking(at: .immediate)
        onSpeakingChange?(false)
    }

    private func finished() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !self.isSpeaking { self.onSpeakingChange?(false) }
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.finished()
        }
    }
}
