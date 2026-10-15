import SwiftUI
import AppKit
import Combine
import JarvisCore

/// First-run guide. Nothing works until the terms are accepted.
struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = AppModel.shared.onboardingStart
    @State private var adult = false
    @State private var agreed = false

    static let interviewStep = 6
    private let titles = ["Welcome", "Terms", "Gemini", "Claude", "Permissions", "Voice", "Meet Jarvis", "How it works", "Ready"]

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                progress
                    .padding(.top, 26)
                    .padding(.leading, 64)
                    .padding(.trailing, 28)
                ScrollView {
                    page
                        .padding(.horizontal, 36)
                        .padding(.vertical, 22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(step)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .opacity))
                }
                footer
                    .padding(.horizontal, 28)
                    .padding(.bottom, 22)
            }
            OrbButton(icon: "xmark", size: 22) { NSApp.keyWindow?.close() }
                .padding(.top, 18)
                .padding(.leading, 20)
                .help("Close. Jarvis stays in the menu bar.")
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: step)
    }

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(titles.indices, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? model.accent : Color.secondary.opacity(0.25))
                    .frame(height: 4)
            }
        }
        .overlay(alignment: .bottomLeading) {
            Text("\(step + 1) of \(titles.count) · \(titles[step])")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .offset(y: 16)
        }
    }

    @ViewBuilder private var page: some View {
        switch step {
        case 0: WelcomePage()
        case 1: TermsPage(adult: $adult, agreed: $agreed)
        case 2: GeminiPage()
        case 3: ClaudePage()
        case 4: PermissionsPage()
        case 5: VoicePage()
        case 6: InterviewPage()
        case 7: TourPage()
        default: ReadyPage()
        }
    }

    private var canContinue: Bool {
        switch step {
        case 1: return adult && agreed
        case 2: return !model.store.geminiKey.isEmpty || !model.store.claudeKey.isEmpty
        default: return true
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
                    .keyboardShortcut(.cancelAction)
            }
            Spacer()
            if step == 2 && !canContinue {
                Text("Add a key to continue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if step == 3 && model.store.claudeKey.isEmpty {
                Button("Skip, use Gemini only") { step += 1 }
            }
            Button(step == titles.count - 1 ? "Start Jarvis" : (step == 1 ? "I agree" : "Continue")) {
                if step == 1 { model.acceptTerms() }
                if step == titles.count - 1 { model.finishOnboarding() } else { step += 1 }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }
}

// MARK: Pages

private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
        }
        .padding(.bottom, 10)
    }
}

private struct Numbered: View {
    let n: Int
    let text: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .frame(width: 22, height: 22)
                .background(model.accent.opacity(0.25), in: Circle())
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WelcomePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 20) {
                OrbView(phase: .listening, accent: model.accent, still: model.store.value.reduceMotion)
                    .frame(width: 120, height: 120)
                PageTitle(title: "Meet Jarvis", subtitle: "A voice assistant that works on your Mac, in front of your eyes.")
            }
            Feature(icon: "waveform", title: "Talk, don't type", text: "Say \u{201C}Jarvis\u{201D} and ask. It answers out loud.")
            Feature(icon: "cursorarrow.motionlines", title: "Watch it work", text: "It moves your real mouse and keyboard and shows every step. Press Esc to stop it instantly.")
            Feature(icon: "bolt.fill", title: "Fast and frugal", text: "Quick questions are answered on this Mac for free. Bigger jobs go to Gemini, or to Claude if you add it.")
            Feature(icon: "square.grid.3x3.fill", title: "Does the work", text: "Calendar, reminders, notes, messages, mail, music, files, Shortcuts, the web, disk cleanup and your screen.")
            Feature(icon: "lock.shield", title: "You stay in control", text: "It asks before sending, deleting, buying or entering passwords. Your keys stay in your Keychain.")
            Text("Setup takes about three minutes.").foregroundStyle(.secondary)
        }
    }
}

private struct Feature: View {
    let icon: String
    let title: String
    let text: String
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(model.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct TermsPage: View {
    @Binding var adult: Bool
    @Binding var agreed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Terms of use", subtitle: "Please read this. Jarvis can act on your computer and accounts.")
            ScrollView {
                Text(Terms.text)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .frame(height: 250)
            .glassCard(14)
            HStack(spacing: 16) {
                Link("Gemini API terms", destination: Links.geminiTerms)
                Link("Google prohibited use policy", destination: Links.googleUsePolicy)
                Link("Anthropic usage policy", destination: Links.claudeUsePolicy)
            }
            .font(.caption)
            Toggle("I am 18 or older.", isOn: $adult)
            Toggle("I have read and accept these terms. I am responsible for how I use Jarvis, and I will follow Google's and Anthropic's usage policies.", isOn: $agreed)
        }
        .toggleStyle(.checkbox)
    }
}

private struct KeyField: View {
    let label: String
    @Binding var key: String
    @State private var reveal = false

    var body: some View {
        HStack {
            Group {
                if reveal { TextField(label, text: $key) } else { SecureField(label, text: $key) }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                .buttonStyle(.borderless)
                .help(reveal ? "Hide" : "Show")
            Button {
                if let s = NSPasteboard.general.string(forType: .string) { key = s.trimmingCharacters(in: .whitespacesAndNewlines) }
            } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        }
    }
}

struct TestResults: View {
    let lines: [TestLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines) { l in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: l.kind == .ok ? "checkmark.circle.fill" : (l.kind == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill"))
                        .foregroundStyle(l.kind == .ok ? .green : (l.kind == .warn ? .orange : .red))
                    Text(l.text).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct GeminiPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Connect Gemini", subtitle: "Jarvis's main brain. The free tier is enough to start.")
            Numbered(n: 1, text: "Open Google AI Studio and sign in with your Google account.")
            Button { NSWorkspace.shared.open(Links.geminiKey) } label: {
                Label("Open Google AI Studio", systemImage: "arrow.up.right.square")
            }
            .padding(.leading, 34)
            Numbered(n: 2, text: "Click \u{201C}Create API key\u{201D}. If it asks, pick or create a project.")
            Numbered(n: 3, text: "Copy the key and paste it here. It's saved only in your Mac's Keychain.")
            KeyField(label: "Gemini API key", key: Binding(get: { model.store.geminiKey }, set: { model.store.geminiKey = $0 }))
                .padding(.leading, 34)
            HStack {
                Button { Task { await model.testGemini() } } label: { Label("Test key", systemImage: "checkmark.seal") }
                    .disabled(model.store.geminiKey.isEmpty || model.testing)
                if model.testing { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 34)
            TestResults(lines: model.geminiTest).padding(.leading, 34)
            Text("A Gemini Plus subscription doesn't include API access; the API key is separate and has its own free daily limits. The test also picks the newest Gemini models your key can use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ClaudePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Add Claude (optional)", subtitle: "Used first when it works. If it doesn't, Jarvis switches to Gemini by itself.")
            Numbered(n: 1, text: "Open the Claude Console and sign in.")
            Button { NSWorkspace.shared.open(Links.claudeConsole) } label: {
                Label("Open Claude Console", systemImage: "arrow.up.right.square")
            }
            .padding(.leading, 34)
            Numbered(n: 2, text: "Go to API keys and create a key.")
            Numbered(n: 3, text: "The Claude API needs prepaid credits (a Claude Pro plan doesn't include them). Without credits, Jarvis simply uses Gemini.")
            KeyField(label: "Claude API key", key: Binding(get: { model.store.claudeKey }, set: { model.store.claudeKey = $0 }))
                .padding(.leading, 34)
            HStack {
                Button { Task { await model.testClaude() } } label: { Label("Test key", systemImage: "checkmark.seal") }
                    .disabled(model.store.claudeKey.isEmpty || model.testing)
                if model.testing { ProgressView().controlSize(.small) }
            }
            .padding(.leading, 34)
            TestResults(lines: model.claudeTest).padding(.leading, 34)
        }
    }
}

struct PermissionsList: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmRepair = false
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.permissions) { p in
                HStack(spacing: 12) {
                    Image(systemName: p.granted == true ? "checkmark.circle.fill" : (p.granted == nil ? "circle.dotted" : "circle.dashed"))
                        .font(.system(size: 18))
                        .foregroundStyle(p.granted == true ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(p.title).font(.headline)
                            if p.optional { MicroLabel(text: "optional") }
                        }
                        Text(p.why).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if p.granted != true {
                        Button(p.id == .automation || p.id == .fullDisk ? "Open" : "Allow") {
                            Task {
                                await Permissions.request(p.id)
                                model.refreshPermissions()
                            }
                        }
                        Button { Permissions.openSettings(p.id) } label: { Image(systemName: "gearshape") }
                            .help("Open System Settings")
                    }
                }
                .padding(10)
                .hudPanel(14, accent: model.accent)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(model.accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Switch already on but Jarvis still asks?").font(.callout.weight(.semibold))
                    Text("Older builds of Jarvis left stale entries behind. Repair clears every permission Jarvis has, relaunches it, and macOS asks once more, cleanly. This only affects Jarvis.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Repair permissions") { confirmRepair = true }
            }
            .padding(.top, 6)
        }
        .onAppear { model.refreshPermissions() }
        .onReceive(timer) { _ in model.refreshPermissions() }
        .confirmationDialog("Reset Jarvis's permissions and relaunch?", isPresented: $confirmRepair) {
            Button("Repair and relaunch") { model.repairPermissions() }
        } message: {
            Text("You'll be asked for Microphone, Speech, Accessibility and Screen Recording again. In System Settings, if Jarvis is listed with its switch on, switch it off and on once.")
        }
    }
}

private struct PermissionsPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageTitle(title: "Permissions", subtitle: "macOS asks for each one once and remembers it. The first four are needed; the rest unlock extra skills.")
            PermissionsList()
            Text("After allowing Screen Recording, macOS may ask you to quit and reopen Jarvis.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct VoicePicker: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let s = model.store.value
        VStack(alignment: .leading, spacing: 12) {
            Picker("Voice type", selection: Binding(get: { model.store.value.voiceEngine }, set: { model.store.value.voiceEngine = $0 })) {
                Text("Mac voice (instant, offline)").tag("apple")
                Text("Gemini studio voice (online)").tag("gemini")
            }
            .pickerStyle(.segmented)

            if s.voiceEngine == "gemini" {
                Picker("Voice", selection: Binding(get: { model.store.value.geminiVoice }, set: { model.store.value.geminiVoice = $0 })) {
                    ForEach(GeminiVoice.voices, id: \.name) { v in Text("\(v.name) · \(v.style)").tag(v.name) }
                }
                TextField("Speaking style", text: Binding(get: { model.store.value.voiceStyle }, set: { model.store.value.voiceStyle = $0 }))
                Text("Studio voices use your Gemini quota. If one isn't available, Jarvis uses the Mac voice instead.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Voice", selection: Binding(get: { model.store.value.voiceID }, set: { model.store.value.voiceID = $0 })) {
                    Text("System default").tag("")
                    ForEach(model.voices) { v in Text("\(v.name) · \(v.language) · \(v.quality)").tag(v.id) }
                }
                Text("For more natural voices, download Premium or Enhanced voices in System Settings, Accessibility, Spoken Content. You can also use your own Personal Voice.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button {
                    model.speaker.say("Good evening. I'm Jarvis, and I'm ready to help.", settings: model.store.value, queue: false)
                } label: { Label("Preview", systemImage: "play.fill") }
                if s.voiceEngine == "apple" {
                    Button("Use my Personal Voice") {
                        Task {
                            if await VoiceCatalog.requestPersonalVoice() { model.voices = VoiceCatalog.all() }
                        }
                    }
                    Button { NSWorkspace.shared.open(Links.spokenContent) } label: { Label("Get more voices", systemImage: "arrow.down.circle") }
                }
            }
        }
    }
}

private struct VoicePage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "Your Jarvis voice", subtitle: "Pick how Jarvis sounds and how you wake it. Next, it'll get to know you by talking.")
            VoicePicker()
            Divider()
            Toggle("Wake Jarvis by saying its name", isOn: Binding(get: { model.store.value.wakeWordEnabled }, set: { model.store.value.wakeWordEnabled = $0 }))
            HStack {
                Text("Wake word")
                TextField("jarvis", text: Binding(get: { model.store.value.wakeWord }, set: { model.store.value.wakeWord = $0 }))
                    .frame(width: 160)
            }
            Picker("Shortcut to talk", selection: Binding(get: { model.store.value.hotkey }, set: { model.store.value.hotkey = $0 })) {
                ForEach(HotKey.labels, id: \.id) { Text($0.label).tag($0.id) }
            }
            .frame(width: 280)
        }
        .onAppear { if !model.voice.running { model.startListening() } }
    }
}

private struct TourPage: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageTitle(title: "How to use Jarvis", subtitle: "A few things worth knowing.")
            Feature(icon: "mic.fill", title: "Say \u{201C}Jarvis\u{201D}, then your request", text: "For example: \u{201C}Jarvis, open Safari and find the weather in Dhaka.\u{201D} You can also press your shortcut and just speak.")
            Feature(icon: "eye", title: "It works where you can see it", text: "The window steps aside, the cursor moves on its own, a ring shows each click, and every step is listed. Press Esc to stop at any moment.")
            Feature(icon: "text.bubble", title: "Answers are spoken and shown", text: "Only the answer appears. Select or copy it with one click, or tap the speaker to hear it again.")
            Feature(icon: "command", title: "One shortcut, from any app", text: "Press your shortcut to open the floating ask bar: speak, or type, and the answer appears right there.")
            Feature(icon: "gauge.with.dots.needle.67percent", title: "It looks after your Mac", text: "Ask how your Mac is doing, what's slowing it down, or to free up disk space. It warns you about low battery, low storage and overheating.")
            Feature(icon: "dock.rectangle", title: "Always within reach", text: "Find Jarvis in the Dock, the menu bar, Spotlight and Launchpad. Settings has every option, including voices, models and safety.")
            Feature(icon: "apps.iphone", title: "Siri and Shortcuts", text: "Make a Shortcut named \u{201C}Ask Jarvis\u{201D} that opens jarvis://listen, then say \u{201C}Hey Siri, Ask Jarvis\u{201D}. Jarvis can also run your Shortcuts.")
        }
    }
}

private struct ReadyPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            OrbView(phase: .speaking, accent: model.accent, still: model.store.value.reduceMotion)
                .frame(width: 200, height: 200)
            Text("You're all set").font(.system(size: 30, weight: .bold, design: .rounded))
            Text("Try saying \u{201C}Jarvis, what can you do?\u{201D}")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 20)
    }
}
