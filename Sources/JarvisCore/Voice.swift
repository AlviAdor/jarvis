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
    /// Someone who stops mid-sentence to find a word and then carries on gets a pause long enough to cover
    /// gaps like the ones they've already made, so they aren't cut off.
    var patient = true
    /// How long this speaker usually pauses mid-sentence, learned over earlier requests.
    var usualGap: TimeInterval = 0
    /// The longest pause in this request after which the speaker carried on.
    private var longestGap: TimeInterval = 0
    private var spoke = false
    /// When the wake word was recognised; the pause just after it is a natural one, not hesitation.
    private var wakeAt: Date?
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
    /// The audio of the request being heard, so it can be sent on when it isn't English.
    private var recording: [AVAudioPCMBuffer] = []

    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let c = AVAudioPCMBuffer(pcmFormat: b.format, frameCapacity: b.frameLength), let src = b.floatChannelData,
              let dst = c.floatChannelData else { return nil }
        c.frameLength = b.frameLength
        for ch in 0..<Int(b.format.channelCount) { dst[ch].update(from: src[ch], count: Int(b.frameLength)) }
        return c
    }

    func takeRecording() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let r = recording
        recording = []
        return r
    }
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
            if recording.count < 400, let c = Self.copy(buffer) { recording.append(c) }
            latestLevel = level
            // Compared with the room's own background level, so a soft voice still counts as speech.
            let voiced = level > max(threshold, noiseFloor * 2.5)
            features.add(buffer, loudEnough: level > max(0.003, noiseFloor * 2.5))
            let now = Date()
            if voiced {
                let gap = now.timeIntervalSince(lastLoud)
                if spoke, gap > 0.35 {
                    if let w = wakeAt, abs(lastLoud.timeIntervalSince(w)) < 1.2 { wakeAt = nil }
                    else { longestGap = max(longestGap, gap) }
                }
                spoke = true
                lastLoud = now
            }
            let quiet = now.timeIntervalSince(lastLoud) > silenceNeeded
            let tooLong = now.timeIntervalSince(began) > (patient ? 40 : 25)
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
        let warm = Date().timeIntervalSince(speakingSince) > 0.6
        let trigger = max(threshold * 1.8, echo * 2.0, noiseFloor * 5)
        if !warm || level <= trigger {
            echo += (level - echo) * (level > echo ? 0.35 : 0.02)
        }
        bargeRun = warm && level > trigger ? bargeRun + 1 : 0
        let fire = bargeRun >= 3
        if fire {
            bargeRun = 0
            // Earlier audio is mostly Jarvis's own voice; keep only the start of what the user is saying.
            preroll = Array(preroll.suffix(2))
        }
        lock.unlock()
        if fire { onBargeIn?() }
    }

    /// The silence that ends a request: the chosen pause, more for a trailing sentence, and for a hesitant
    /// speaker a little more than the pauses they've been making.
    private var silenceNeeded: TimeInterval {
        var need = max(0.7, pause + extraPause)
        if patient {
            let cover = max(longestGap + 0.5, usualGap + 0.3)
            if cover > need { need = min(pause + 1.8, cover) }
        }
        return need
    }

    /// The wake word just ended: earlier pauses and the natural one after "Hey Jarvis" don't count.
    func forgetGaps() {
        lock.lock(); longestGap = 0; wakeAt = Date(); lock.unlock()
    }

    func takeGap() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return longestGap
    }

    func takeVector() -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        return features.vector()
    }

    func attach(_ req: SFSpeechAudioBufferRecognitionRequest) {
        lock.lock()
        features.reset()
        for b in preroll { req.append(b) }
        recording = preroll.compactMap { Self.copy($0) }
        preroll.removeAll()
        request = req
        lastLoud = Date()
        began = Date()
        ended = false
        extraPause = 0
        longestGap = 0
        spoke = false
        wakeAt = nil
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
    /// The voice didn't match; with what was said and the voiceprint, so the user can say "it was me".
    public var onRejected: ((String, [Float]) -> Void)?
    /// How closely the last request matched the user's voice, and what it needed.
    @Published public private(set) var lastMatch: (score: Float, needed: Float)?
    /// Words recognition should expect, such as the wake word and the user's name.
    public var vocabulary: [String] = []
    /// Phrases recognition leans towards: names, places, apps and words the user taught it.
    public var hints: [String] = []
    /// A model of typical requests with this user's words, used when recognition runs on this Mac.
    public var languageModel: SFSpeechLanguageModel.Configuration?
    public var recognitionLocale: Locale? { recognizer?.locale }
    private var learnedSinceSave = 0
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

    /// Searching for a word: a filler ("um", "how do you say"), or a word said twice ("I I want", "the the").
    nonisolated public static func soundsHesitant(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        let tail = Array(words.suffix(6))
        guard !tail.isEmpty else { return false }
        let fillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "erm", "er", "hmm", "hm", "mm", "ah", "eh", "ehm"]
        if tail.contains(where: fillers.contains) { return true }
        let end = tail.joined(separator: " ")
        if ["how do you say", "what's it called", "what is it called", "what do you call it", "let me think", "let me see", "i mean"]
            .contains(where: end.hasSuffix) { return true }
        return zip(tail, tail.dropFirst()).contains { $0 == $1 }
    }

    public var pause: TimeInterval {
        get { gate.pause }
        set { gate.pause = newValue }
    }
    /// Waits longer for someone who pauses mid-sentence to find a word.
    public var patient: Bool {
        get { gate.patient }
        set { gate.patient = newValue }
    }
    /// How long this speaker usually pauses mid-sentence; saved so patience starts from the first request.
    public var usualGap: TimeInterval {
        get { gate.usualGap }
        set { gate.usualGap = min(1.6, max(0, newValue)) }
    }
    /// The learned pause changed enough to be worth keeping.
    public var onUsualGap: ((TimeInterval) -> Void)?
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

    /// Too little audio to judge is let through; only a clear mismatch is turned away.
    /// Confident matches, and anything said after pressing the shortcut, teach the profile a little more.
    private func passesLock(_ v: [Float]?) -> Bool {
        guard let profile, let v else { return true }
        let score = profile.score(v), needed = profile.threshold(strictness: lockStrictness)
        lastMatch = (score, needed)
        if pushArmed || score >= needed + 0.04 { learn(v) }
        guard lockEnabled, !pushArmed else { return true }
        return score >= needed
    }

    private func learn(_ v: [Float]) {
        guard var p = profile else { return }
        p.learn(v)
        profile = p
        learnedSinceSave += 1
        if learnedSinceSave >= 3 { p.save(); learnedSinceSave = 0 }
    }

    /// The user says a rejected request was theirs: learn from it.
    public func confirmMine(_ v: [Float]) {
        learn(v)
        profile?.save()
    }

    /// Fuzzy match for the wake word, since recognition often hears "Jervis" or "Javis".
    nonisolated public static func isWake(_ word: String, wakeWord: String = "jarvis") -> Bool {
        let w = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let target = wakeWord.lowercased()
        if w == target || w == "jarvis" { return true }
        guard w.count >= 4, abs(w.count - target.count) <= 2, let f = w.first, let tf = target.first else { return false }
        let sameStart = f == tf || (tf == "j" && "gcy".contains(f))
        return sameStart && distance(w, target) <= (target.count >= 6 ? 2 : 1)
    }

    nonisolated static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var prev = Array(0...b.count)
        for i in 1...max(a.count, 1) where !a.isEmpty {
            var cur = [i] + Array(repeating: 0, count: b.count)
            for j in 1...max(b.count, 1) where !b.isEmpty {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[b.count]
    }

    private func beginUtterance() {
        guard running, request == nil, let recognizer, recognizer.isAvailable else { gate.detach(); return }
        // Ambient speech is ignored unless wake word listening is on or the user armed us.
        guard wakeEnabled || armed || enrollProgress != nil || capturing else { gate.detach(); return }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.addsPunctuation = true
        // Bias recognition towards the words that matter most: the wake word, the user's names, places and apps.
        req.contextualStrings = hints.isEmpty ? Array(Set(["Jarvis", "Hey Jarvis", wakeWord.capitalized] + vocabulary)).filter { !$0.isEmpty } : hints
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
            if let languageModel { req.customizedLanguageModel = languageModel }
        }
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
            let segs = result?.bestTranscription.segments ?? []
            let confidence = segs.isEmpty ? Float(0) : segs.map(\.confidence).reduce(0, +) / Float(segs.count)
            Task { @MainActor in self?.update(text, final: final, confidence: confidence) }
        }
    }

    private func update(_ text: String?, final: Bool, confidence: Float = 0) {
        if let text, armed || capturing || containsWake(text) || enrollProgress != nil {
            if partial.isEmpty, !armed, !capturing, enrollProgress == nil { onWakeHeard?() }
            partial = text
            // A sentence that sounds finished ends sooner; one that trails off gets more time, and so does
            // someone still finding their words (the recogniser's full stop doesn't count then).
            let t = text.trimmingCharacters(in: .whitespaces)
            var extra: TimeInterval = Self.soundsUnfinished(text) ? 1.6 : (t.hasSuffix("?") || t.hasSuffix(".") || t.hasSuffix("!")) ? -0.6 : 0
            if gate.patient, Self.soundsHesitant(text) { extra = min(2.2, max(extra, 0) + 0.9) }
            gate.extraPause = extra
            if endsWithWake(t) { gate.forgetGaps() }
        }
        guard final else { return }
        let heard = text ?? partial
        request = nil
        task = nil
        hearing = false
        levelTimer?.invalidate()
        level = 0
        let vector = gate.takeVector()
        let audio = gate.takeRecording()
        if armed || capturing { learnGap(gate.takeGap()) }
        lastConfidence = confidence
        lastAudio = audio
        gate.detach()
        if capturing {
            capturing = false
            armTimeout?.cancel()
            onAnswer?(heard.trimmingCharacters(in: .whitespacesAndNewlines), vector)
        } else if enrollProgress != nil {
            collect(vector, heard: heard)
        } else if passesLock(vector) {
            deliver(heard)
        } else if containsWake(heard) || armed, let vector {
            onRejected?(heard, vector)
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

    /// Follows how the speaker talks: pauses mid-sentence pull the usual gap up, fluent requests let it drift down.
    private func learnGap(_ gap: TimeInterval) {
        let before = usualGap
        usualGap = gap > 0.35 ? before * 0.7 + gap * 0.3 : before * 0.9
        if abs(usualGap - before) > 0.05 { onUsualGap?(usualGap) }
    }

    private func endsWithWake(_ s: String) -> Bool {
        guard let r = wakeRange(in: s) else { return false }
        return s[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).isEmpty
    }

    private func containsWake(_ s: String) -> Bool {
        wakeRange(in: s) != nil
    }

    private func wakeRange(in s: String) -> Range<String.Index>? {
        let lower = s.lowercased()
        for w in [wakeWord.lowercased(), "jarvis"] {
            if let r = lower.range(of: w) { return r }
        }
        // Near misses: the first word that sounds like the wake word.
        var idx = lower.startIndex
        for word in lower.split(separator: " ", omittingEmptySubsequences: true) {
            guard let r = lower.range(of: word, range: idx..<lower.endIndex) else { continue }
            idx = r.upperBound
            if Self.isWake(String(word), wakeWord: wakeWord) { return r }
        }
        return nil
    }

    /// What was asked, without the wake word in front.
    public func command(in heard: String) -> String {
        let t = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let r = wakeRange(in: t) else { return t }
        return String(t[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?"))
    }

    /// How sure the recogniser was about the last request (0 when it didn't say), and that request's audio.
    public private(set) var lastConfidence: Float = 0
    private var lastAudio: [AVAudioPCMBuffer] = []

    /// The last request as a 16 kHz mono WAV, for a model that understands speech in any language.
    public func lastRecordingWAV() -> Data? { Self.wav(from: lastAudio) }

    nonisolated public static func wav(from buffers: [AVAudioPCMBuffer], rate: Double = 16_000) -> Data? {
        guard let first = buffers.first,
              let target = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let conv = AVAudioConverter(from: first.format, to: target) else { return nil }
        var pcm = Data()
        var index = 0
        let total = buffers.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(total) * rate / first.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            guard index < buffers.count else { status.pointee = .endOfStream; return nil }
            status.pointee = .haveData
            defer { index += 1 }
            return buffers[index]
        }
        guard err == nil, let ch = out.int16ChannelData, out.frameLength > 0 else { return nil }
        pcm.append(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
        var header = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
        header.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        header.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        header.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        return header + pcm
    }

    /// Called when the user says only the wake word, so Jarvis can answer "Yes?".
    public var onWakeOnly: (() -> Void)?

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
                onWakeOnly?()
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
    /// Called with a language code when no Mac voice can speak it.
    public var onMissingVoice: ((String) -> Void)?
    private var lastLanguage: String?
    public var geminiKey: () -> String = { "" }
    /// Short phrases already spoken in the Gemini voice, kept so greetings play instantly and cost nothing.
    private static let cacheDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Jarvis/voice-cache")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private static func cacheURL(_ text: String, _ s: JarvisSettings) -> URL {
        let key = "\(s.geminiVoice)|\(s.voiceStyle)|\(text)"
        var h: UInt64 = 1469598103934665603
        for b in key.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return cacheDir.appendingPathComponent(String(h, radix: 16) + ".wav")
    }
    /// Models this key can use, so the voice can move to another voice model when one runs out.
    public var knownModels: () -> [String] = { [] }

    public var isSpeaking: Bool { synth.isSpeaking || (player?.isPlaying ?? false) || fetch != nil || nextPiece < pieceCount }

    // Speaking while the answer is still arriving.
    private enum Piece { case audio(Data), text(String) }
    private var pieces: [Int: Piece] = [:]
    private var nextPiece = 0
    private var pieceCount = 0
    private var partTasks: [Task<Void, Never>] = []
    private var partSettings: JarvisSettings?

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks with the voice chosen in settings. The Gemini voice falls back to the Mac's voice on any error.
    /// Called each time a reply is sent to Gemini to be spoken, so the request is counted.
    public var onCloudUse: (() -> Void)?

    /// What Jarvis said lately, so the mic catching its own voice isn't taken for a request.
    public private(set) var recentSpeech = ""

    private func noteSpoken(_ text: String) {
        recentSpeech = String((recentSpeech + " " + text).suffix(800))
    }

    public func say(_ text: String, settings s: JarvisSettings, queue: Bool = true) {
        noteSpoken(text)
        if s.usageSaver {
            sayLocal(text, settings: s, queue: queue)
            return
        }
        if s.voiceEngine == "gemini", !geminiKey().isEmpty {
            sayGemini(text, s)
            return
        }
        // A language no Mac voice on this Mac can speak: Gemini's voice speaks almost any language.
        if let lang = Language.detect(text), Language.voice(for: lang) == nil, !geminiKey().isEmpty,
           QuotaBook.shared.usable(s.ttsModel) {
            sayGemini(text, s)
            return
        }
        sayLocal(text, settings: s, queue: queue)
    }

    /// Always the Mac's own voice: instant, offline, used for streamed sentences and short step narration.
    public func sayLocal(_ text: String, settings s: JarvisSettings, queue: Bool = true) {
        if !queue { stop() }
        let u = AVSpeechUtterance(string: text)
        u.rate = Float(s.voiceRate)
        u.pitchMultiplier = Float(s.voicePitch)
        u.volume = Float(s.voiceVolume)
        // Speak each language in a voice that knows it; the chosen voice is used whenever it fits.
        let lang = Language.detect(text) ?? lastLanguage
        if let lang { lastLanguage = lang }
        let chosen = s.voiceID.isEmpty ? nil : AVSpeechSynthesisVoice(identifier: s.voiceID)
        if let lang, !(chosen?.language.lowercased().hasPrefix(lang.lowercased()) ?? lang.hasPrefix("en")) {
            if let v = Language.voice(for: lang) { u.voice = v } else { onMissingVoice?(lang) }
        } else if let chosen {
            u.voice = chosen
        }
        onSpeakingChange?(true)
        synth.speak(u)
    }

    private func sayGemini(_ text: String, _ s: JarvisSettings) {
        stop()
        onSpeakingChange?(true)
        let key = geminiKey()
        let cached = text.count <= 80 ? Self.cacheURL(text, s) : nil
        if let cached, let wav = try? Data(contentsOf: cached), let p = try? AVAudioPlayer(data: wav) {
            p.delegate = self
            p.volume = Float(s.voiceVolume)
            player = p
            p.play()
            return
        }
        onCloudUse?()
        fetch = Task { [weak self] in
            do {
                let wav = try await GeminiVoice.synthesize(text, voice: s.geminiVoice, style: s.voiceStyle, model: s.ttsModel, key: key, known: self?.knownModels() ?? [])
                guard let self, !Task.isCancelled else { return }
                self.fetch = nil
                if let cached { try? wav.write(to: cached, options: .atomic) }
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

    /// Speaks part of an answer as soon as it's ready, in order after the parts before it. With the Gemini
    /// voice each part is turned into audio while earlier parts play, so speech starts at the first sentence.
    public func sayPart(_ text: String, settings s: JarvisSettings) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        noteSpoken(t)
        let gemini = s.voiceEngine == "gemini" && !s.usageSaver && !geminiKey().isEmpty && QuotaBook.shared.usable(s.ttsModel)
        let seq = pieceCount
        pieceCount += 1
        partSettings = s
        onSpeakingChange?(true)
        guard gemini else {
            pieces[seq] = .text(t)
            playNextPiece()
            return
        }
        let cached = t.count <= 80 ? Self.cacheURL(t, s) : nil
        if let cached, let wav = try? Data(contentsOf: cached) {
            pieces[seq] = .audio(wav)
            playNextPiece()
            return
        }
        onCloudUse?()
        let key = geminiKey(), known = knownModels()
        partTasks.append(Task { [weak self] in
            let wav = try? await GeminiVoice.synthesize(t, voice: s.geminiVoice, style: s.voiceStyle, model: s.ttsModel, key: key, known: known)
            guard let self, !Task.isCancelled else { return }
            if let wav, let cached { try? wav.write(to: cached, options: .atomic) }
            self.pieces[seq] = wav.map { .audio($0) } ?? .text(t)
            self.playNextPiece()
        })
    }

    private func playNextPiece() {
        guard player == nil, !synth.isSpeaking, let s = partSettings, let piece = pieces.removeValue(forKey: nextPiece) else { return }
        nextPiece += 1
        switch piece {
        case .audio(let d):
            guard let p = try? AVAudioPlayer(data: d) else { playNextPiece(); return }
            p.delegate = self
            p.volume = Float(s.voiceVolume)
            player = p
            p.play()
        case .text(let t):
            sayLocal(t, settings: s)
        }
    }

    public func stop() {
        partTasks.forEach { $0.cancel() }
        partTasks = []
        pieces = [:]
        nextPiece = 0
        pieceCount = 0
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
        Task { @MainActor in
            self.playNextPiece()
            self.finished()
        }
    }

    nonisolated public func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }

    nonisolated public func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playNextPiece()
            self.finished()
        }
    }
}
