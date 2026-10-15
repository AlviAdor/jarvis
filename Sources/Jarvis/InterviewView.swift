import SwiftUI
import AppKit
import Combine
import JarvisCore

/// Runs the spoken getting-to-know-you chat: Jarvis asks out loud, listens for the answer, notes what it
/// understood, and keeps a voiceprint of every answer so it learns the voice of the person actually speaking.
@MainActor
final class InterviewSession: ObservableObject {
    enum Stage { case ready, asking, listening, missed, thinking, finished }

    @Published private(set) var stage: Stage = .ready
    @Published private(set) var question = ""
    @Published private(set) var step = 0
    @Published private(set) var understood: [(label: String, value: String)] = []
    @Published private(set) var samples = 0
    @Published var typed = ""

    let total = Interview.questions(name: "").count
    private let model: AppModel
    private var current: Interview.Question?
    private var vectors: [[Float]] = []
    private var transcript: [(question: String, answer: String)] = []
    private var extra = 0
    private var bag = Set<AnyCancellable>()

    init(model: AppModel) {
        self.model = model
        model.$speaking.removeDuplicates().sink { [weak self] speaking in
            guard let self, !speaking, self.stage == .asking else { return }
            self.listen()
        }.store(in: &bag)
    }

    var voiceLearned: Bool { samples >= 3 }

    func start() {
        model.voice.onAnswer = { [weak self] text, vector in self?.heard(text, vector) }
        if !model.voice.running { model.startListening() }
        step = 0
        extra = 0
        vectors = []
        transcript = []
        understood = []
        samples = 0
        ask()
    }

    func stop() {
        model.voice.stopCapture()
        model.voice.onAnswer = nil
        model.speaker.stop()
    }

    private func nextQuestion() -> Interview.Question? {
        let qs = Interview.questions(name: model.store.value.userName)
        if step < qs.count { return qs[step] }
        if samples < Interview.samplesNeeded, extra < Interview.voicePrompts.count {
            return Interview.Question(field: .voice, text: Interview.voicePrompts[extra])
        }
        return nil
    }

    private func ask() {
        guard let q = nextQuestion() else { Task { await finish() }; return }
        current = q
        question = q.text
        typed = ""
        stage = .asking
        model.voice.stopCapture()
        model.speaker.say(q.text, settings: model.store.value, queue: false)
        // If speech is off or fails silently, listen anyway after a moment.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, self.stage == .asking, !self.model.speaking else { return }
            self.listen()
        }
    }

    private func listen() {
        stage = .listening
        model.voice.captureAnswer(timeout: 14)
    }

    /// Listen again for the same question.
    func retry() { listen() }

    /// Ask the question again out loud.
    func repeatQuestion() { ask() }

    func skip() {
        model.voice.stopCapture()
        model.speaker.stop()
        if let q = current { transcript.append((q.text, "")) }
        advance()
    }

    func submitTyped() {
        let t = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        model.voice.stopCapture()
        heard(t, nil)
    }

    private func heard(_ text: String, _ vector: [Float]?) {
        guard let q = current, stage == .listening || !typed.isEmpty else { return }
        if text.isEmpty {
            stage = .missed
            return
        }
        if let vector {
            vectors.append(vector)
            samples = vectors.count
        }
        transcript.append((q.text, text))
        apply(q.field, text)
        advance()
    }

    private func advance() {
        if current?.field == .voice { extra += 1 } else { step += 1 }
        ask()
    }

    private func note(_ label: String, _ value: String) {
        guard !value.isEmpty else { return }
        understood.removeAll { $0.label == label }
        understood.append((label, value))
    }

    private func apply(_ field: Interview.Field, _ text: String) {
        switch field {
        case .name:
            let n = Interview.name(from: text)
            if !n.isEmpty { model.store.value.userName = n; note("Name", n) }
        case .work:
            let w = Interview.work(from: text)
            if !w.isEmpty { model.store.value.aboutWork = w; note("Does", w) }
        case .place:
            let p = Interview.place(from: text)
            if !p.isEmpty { model.store.value.aboutPlace = p; note("Based in", p) }
        case .focus:
            let f = Interview.focus(from: text)
            if !f.isEmpty { model.store.value.aboutFocus = f; note("Help with", f.joined(separator: ", ")) }
            else if !Interview.notes(from: text).isEmpty { note("Help with", text) }
        case .style:
            let st = Interview.style(from: text)
            model.store.value.answerStyle = st
            note("Answers", st.capitalized)
        case .notes:
            let n = Interview.notes(from: text)
            if !n.isEmpty { model.store.value.aboutNotes = n; note("Also", n) }
        case .voice:
            break
        }
    }

    private func finish() async {
        stage = .thinking
        model.voice.stopCapture()
        if vectors.count >= 3, let p = VoiceProfile.enroll(vectors) {
            model.voice.adopt(p)
            model.store.value.voiceLockEnabled = true
        }
        let s = model.store.value
        if let p = await Interview.refine(transcript, key: model.store.geminiKey, model: s.liteModel) {
            if !p.name.isEmpty { model.store.value.userName = p.name; note("Name", p.name) }
            if !p.work.isEmpty { model.store.value.aboutWork = p.work; note("Does", p.work) }
            if !p.place.isEmpty { model.store.value.aboutPlace = p.place; note("Based in", p.place) }
            if !p.focus.isEmpty { model.store.value.aboutFocus = p.focus; note("Help with", p.focus.joined(separator: ", ")) }
            if !p.style.isEmpty { model.store.value.answerStyle = p.style; note("Answers", p.style.capitalized) }
            if !p.notes.isEmpty { model.store.value.aboutNotes = p.notes; note("Also", p.notes) }
            p.facts.forEach { model.memory.addFact($0) }
        }
        stage = .finished
        let name = model.store.value.userName
        question = voiceLearned
            ? "Thanks\(name.isEmpty ? "" : ", \(name)"). I've got to know you, and I'll recognise your voice from now on."
            : "Thanks\(name.isEmpty ? "" : ", \(name)"). I've got to know you. I didn't hear enough to learn your voice yet; you can do that later in Settings."
        model.speaker.say(question, settings: model.store.value, queue: false)
        model.voice.onAnswer = nil
    }
}

/// The setup page where Jarvis and the user talk.
struct InterviewPage: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var session = InterviewSession(model: AppModel.shared)
    @ObservedObject private var voice = AppModel.shared.voice

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Let's get to know each other").font(.system(size: 28, weight: .bold, design: .rounded))
                Text("Jarvis asks a few questions out loud. Just answer naturally; it learns about you and your voice as you talk.")
                    .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .center, spacing: 22) {
                OrbView(phase: orbPhase, accent: model.accent, still: model.store.value.reduceMotion, level: voice.level)
                    .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 10) {
                    if session.stage == .ready {
                        Text("Ready when you are. Make sure you're somewhere fairly quiet.")
                            .font(.title3)
                        Button { session.start() } label: { Label("Start talking with Jarvis", systemImage: "waveform") }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                    } else {
                        MicroLabel(text: stageLabel, color: model.accent)
                        Text(session.question)
                            .font(.system(size: 19, weight: .medium, design: .rounded))
                            .fixedSize(horizontal: false, vertical: true)
                        if session.stage == .listening, !voice.partial.isEmpty {
                            Text("\u{201C}\(voice.partial)\u{201D}")
                                .font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        if session.stage == .missed {
                            Text("I didn't catch that.").font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if session.stage != .ready && session.stage != .finished && session.stage != .thinking {
                HStack(spacing: 10) {
                    Button { session.retry() } label: { Label("Listen again", systemImage: "mic") }
                        .disabled(session.stage == .listening)
                    Button { session.repeatQuestion() } label: { Label("Repeat question", systemImage: "arrow.counterclockwise") }
                    Button("Skip") { session.skip() }
                    Spacer()
                    TextField("Or type your answer", text: $session.typed)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .onSubmit { session.submitTyped() }
                }
                .controlSize(.small)
            }
            if session.stage == .thinking { ProgressView("Putting it all together…").controlSize(.small) }

            HStack(spacing: 14) {
                if session.stage != .ready {
                    progressDots(done: min(questionsDone, session.total), of: session.total, label: "Questions")
                }
                if session.stage != .ready {
                    progressDots(done: min(session.samples, Interview.samplesNeeded), of: Interview.samplesNeeded, label: "Your voice")
                }
            }

            if !session.understood.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    MicroLabel(text: "What Jarvis understood")
                    ForEach(session.understood, id: \.label) { item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
                            Text(item.value).font(.callout).lineLimit(2)
                        }
                    }
                    Text("You can correct any of this in Settings, Memory.").font(.caption2).foregroundStyle(.tertiary)
                }
                .padding(12)
                .hudPanel(14, accent: model.accent)
            }
        }
        .onDisappear { session.stop() }
    }

    private var questionsDone: Int { session.stage == .finished ? session.total : session.step }

    private var orbPhase: Phase {
        switch session.stage {
        case .ready, .missed: return .idle
        case .asking: return .speaking
        case .listening: return .listening
        case .thinking: return .thinking
        case .finished: return model.speaking ? .speaking : .idle
        }
    }

    private var stageLabel: String {
        switch session.stage {
        case .ready: return ""
        case .asking: return "Jarvis is asking"
        case .listening: return "Listening to you"
        case .missed: return "Your turn"
        case .thinking: return "Thinking"
        case .finished: return "All done"
        }
    }

    private func progressDots(done: Int, of total: Int, label: String) -> some View {
        HStack(spacing: 6) {
            MicroLabel(text: label)
            ForEach(0..<total, id: \.self) { i in
                Circle().fill(i < done ? model.accent : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
            }
        }
    }
}
