import Foundation
import Speech
import AVFoundation

@MainActor
public final class VoiceInput: ObservableObject {
    @Published public private(set) var partial = ""
    @Published public private(set) var listening = false
    public var onFinal: ((String) -> Void)?

    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Timer?

    public init() {}

    public static func authorize() async -> Bool {
        let speech = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return speech && mic
    }

    public func start() throws {
        guard !listening, let recognizer, recognizer.isAvailable else { return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        partial = ""

        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()
        listening = true

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let done = (result?.isFinal ?? false) || error != nil
            Task { @MainActor in self?.update(text, done: done) }
        }
    }

    private func update(_ text: String?, done: Bool) {
        guard listening else { return }
        if let text, !text.isEmpty {
            partial = text
            silence?.invalidate()
            silence = Timer.scheduledTimer(withTimeInterval: 1.4, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.finish() }
            }
        }
        if done { finish() }
    }

    public func finish() {
        guard listening else { return }
        let text = partial
        stop()
        if !text.isEmpty { onFinal?(text) }
    }

    public func stop() {
        silence?.invalidate()
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        listening = false
    }
}

@MainActor
public final class Speaker {
    private let synth = AVSpeechSynthesizer()
    public init() {}

    public func say(_ text: String, rate: Double) {
        let u = AVSpeechUtterance(string: text)
        u.rate = Float(rate)
        synth.speak(u)
    }

    public func stop() { synth.stopSpeaking(at: .immediate) }
}
