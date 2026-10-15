import SwiftUI
import AppKit
import JarvisCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            KeysTab().tabItem { Label("Keys", systemImage: "key") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            ToolsTab().tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
            MacTab().tabItem { Label("Mac", systemImage: "laptopcomputer") }
            SafetyTab().tabItem { Label("Safety", systemImage: "lock.shield") }
            AutomationsTab().tabItem { Label("Automations", systemImage: "clock") }
            MemoryTab().tabItem { Label("Memory", systemImage: "brain") }
            LookTab().tabItem { Label("Look", systemImage: "paintbrush") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 580)
        .preferredColorScheme(model.colorScheme)
        .tint(model.accent)
    }
}

@MainActor
private func bind<T>(_ model: AppModel, _ kp: WritableKeyPath<JarvisSettings, T>) -> Binding<T> {
    Binding(get: { model.store.value[keyPath: kp] }, set: { model.store.value[keyPath: kp] = $0 })
}

private struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: General

private struct GeneralTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("You") {
                TextField("Your name", text: bind(model, \.userName))
            }
            Section("App") {
                Toggle("Show Jarvis in the Dock", isOn: bind(model, \.showInDock))
                Toggle("Open the window when Jarvis starts", isOn: bind(model, \.openWindowAtLaunch))
                Toggle("Open Jarvis at login", isOn: bind(model, \.launchAtLogin))
                Picker("Shortcut to talk", selection: bind(model, \.hotkey)) {
                    ForEach(HotKey.labels, id: \.id) { Text($0.label).tag($0.id) }
                }
                Toggle("The shortcut opens the floating ask bar", isOn: bind(model, \.quickPanel))
                Toggle("Show earlier answers in the window", isOn: bind(model, \.keepHistory))
                Toggle("Show live Mac readings (CPU, memory, storage, battery)", isOn: bind(model, \.showTelemetry))
            }
            Section("While Jarvis works") {
                Toggle("Show the floating status bubble", isOn: bind(model, \.overlayEnabled))
                Toggle("Show a ring where it clicks", isOn: bind(model, \.showHighlights))
                Toggle("Say each step out loud", isOn: bind(model, \.narrateActions))
                Toggle("Ask before every step", isOn: bind(model, \.stepByStep))
                Toggle("Show technical details", isOn: bind(model, \.userDetails))
            }
            Section {
                Button("Replay the welcome tour") { model.replayOnboarding() }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Keys

private struct KeysTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                SecureField("Gemini API key", text: Binding(get: { model.store.geminiKey }, set: { model.store.geminiKey = $0 }))
                HStack {
                    Button { Task { await model.testGemini() } } label: { Label("Test Gemini", systemImage: "checkmark.seal") }
                        .disabled(model.store.geminiKey.isEmpty || model.testing)
                    Link("Get a free key", destination: Links.geminiKey)
                    if model.testing { ProgressView().controlSize(.small) }
                }
                TestResults(lines: model.geminiTest)
            } header: { Text("Gemini (main)") }

            Section {
                SecureField("Claude API key", text: Binding(get: { model.store.claudeKey }, set: { model.store.claudeKey = $0 }))
                Toggle("Use Claude first when it works", isOn: bind(model, \.claudeEnabled))
                HStack {
                    Button { Task { await model.testClaude() } } label: { Label("Test Claude", systemImage: "checkmark.seal") }
                        .disabled(model.store.claudeKey.isEmpty || model.testing)
                    Link("Claude Console", destination: Links.claudeConsole)
                }
                TestResults(lines: model.claudeTest)
                Hint("Claude needs prepaid API credits. If it fails for any reason, Jarvis switches to Gemini automatically and stops retrying Claude for 30 minutes.")
            } header: { Text("Claude (optional)") }

            Section {
                Hint("Keys are stored in your Mac's Keychain, readable only on this Mac while you're logged in, and never shown in logs.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Models

private struct ModelsTab: View {
    @EnvironmentObject var model: AppModel

    private func picker(_ title: String, _ kp: WritableKeyPath<JarvisSettings, String>) -> some View {
        let current = model.store.value[keyPath: kp]
        let options = Array(Set(model.availableModels + [current])).sorted()
        return Picker(title, selection: bind(model, kp)) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: bind(model, \.localEngine)) {
                    Text("Auto (Ollama when running, else Apple)").tag("auto")
                    Text("Apple on-device model").tag("apple")
                    Text("Ollama").tag("ollama")
                    Text("Off").tag("off")
                }
                if !model.ollamaModels.isEmpty {
                    Picker("Ollama model", selection: bind(model, \.ollamaModel)) {
                        Text("Smallest installed").tag("")
                        ForEach(model.ollamaModels, id: \.self) { Text($0).tag($0) }
                    }
                }
                HStack {
                    Button { Task { await model.testLocal() } } label: { Label("Test local model", systemImage: "bolt") }
                        .disabled(model.testing)
                    Link("Get Ollama", destination: URL(string: "https://ollama.com")!)
                }
                TestResults(lines: model.localTest)
                Hint("Quick questions are answered on this Mac for free and in about a second. Anything that needs the web, your screen, tools or deep thinking goes to the cloud automatically.")
            } header: { Text("On this Mac") }
            Section("Ollama") {
                OllamaSetup()
            }

            Section {
                Picker("Mode", selection: bind(model, \.modelChoice)) {
                    Text("Auto (cheapest model that fits)").tag("auto")
                    Text("Always lite").tag("lite")
                    Text("Always flash").tag("flash")
                    Text("Always pro").tag("pro")
                }
                picker("Lite (quick replies, routing)", \.liteModel)
                picker("Flash (screen, web)", \.flashModel)
                picker("Pro (hard problems)", \.proModel)
                HStack {
                    Button("Use the newest models my key has") {
                        Task {
                            if model.availableModels.isEmpty { await model.testGemini() } else { model.useNewestModels() }
                        }
                    }
                    if model.testing { ProgressView().controlSize(.small) }
                }
            } header: { Text("Gemini") }

            Section {
                TextField("Quick", text: bind(model, \.claudeLiteModel))
                TextField("Screen", text: bind(model, \.claudeFlashModel))
                TextField("Hard", text: bind(model, \.claudeProModel))
            } header: { Text("Claude") }

            Section {
                let resting = QuotaBook.shared.status()
                if resting.isEmpty {
                    Text("Every model has free requests available.").foregroundStyle(.secondary)
                } else {
                    ForEach(resting, id: \.self) { Text($0).font(.callout) }
                    Button("Try them again now") { QuotaBook.shared.clear(); model.flash("Cleared") }
                }
                Hint("Gemini's free tier gives each model a few requests a minute and a daily allowance; some Pro models have none. When one runs out, Jarvis switches to another model and comes back when it resets. AI Studio's usage page updates late and doesn't show refused requests.")
            } header: { Text("Free tier") }

            Section {
                Stepper("Cloud requests per day: \(model.store.value.dailyRequestCap)", value: bind(model, \.dailyRequestCap), in: 20...5000, step: 20)
                Stepper("Most steps for a screen task: \(model.store.value.maxSteps)", value: bind(model, \.maxSteps), in: 5...100, step: 5)
            } header: { Text("Limits") }
        }
        .formStyle(.grouped)
    }
}

// MARK: Voice

private struct VoiceTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Jarvis's voice") {
                VoicePicker()
                Slider(value: bind(model, \.voiceRate), in: 0.3...0.65) { Text("Speed") }
                Slider(value: bind(model, \.voicePitch), in: 0.7...1.4) { Text("Pitch") }
                Slider(value: bind(model, \.voiceVolume), in: 0.2...1.0) { Text("Volume") }
                Toggle("Speak answers", isOn: bind(model, \.speakReplies))
                if model.store.value.voiceEngine == "gemini" {
                    Picker("Studio voice model", selection: bind(model, \.ttsModel)) {
                        ForEach(GeminiVoice.models, id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section("Listening") {
                Toggle("Listen for the wake word", isOn: bind(model, \.wakeWordEnabled))
                TextField("Wake word", text: bind(model, \.wakeWord))
                Slider(value: bind(model, \.micThreshold), in: 0.002...0.04) { Text("Needs louder speech") }
                Toggle("Stop talking when I start speaking", isOn: bind(model, \.bargeIn))
                Toggle("Answer by name when I say just \u{201C}\(model.store.value.wakeWord.capitalized)\u{201D}", isOn: bind(model, \.answerWhenCalled))
                Toggle("Greet me when Jarvis starts", isOn: bind(model, \.greetOnLaunch))
                Slider(value: bind(model, \.responsePause), in: 0.8...3.0) {
                    Text(String(format: "Reply after a %.1f s pause", model.store.value.responsePause))
                }
                Hint("Speech is recognized on this Mac when the on-device model is available. Nothing leaves your Mac until you say the wake word and ask something.")
            }
            Section("Recognise my voice (experimental)") {
                VoiceMatchControls(voice: model.voice)
            }
        }
        .formStyle(.grouped)
    }
}

struct VoiceMatchControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var voice: VoiceEngine
    private let lines = [
        "Jarvis, what's on my calendar today?",
        "The quick brown fox jumps over the lazy dog.",
        "Open Safari and search for the weather.",
        "I'd like a cup of coffee and some quiet music.",
        "Remind me to call home at six this evening.",
    ]

    var body: some View {
        Toggle("Only respond to my voice", isOn: bind(model, \.voiceLockEnabled))
            .disabled(voice.profile == nil)
        Slider(value: bind(model, \.voiceLockStrictness), in: 0...1) { Text("Strictness") }
            .disabled(voice.profile == nil)
        if let n = voice.enrollProgress {
            VStack(alignment: .leading, spacing: 6) {
                Text("Read this aloud (\(n + 1) of \(VoiceEngine.enrollTarget)):").font(.callout)
                Text("\u{201C}\(lines[min(n, lines.count - 1)])\u{201D}").font(.title3.weight(.medium))
                ProgressView(value: Double(n), total: Double(VoiceEngine.enrollTarget))
                Button("Cancel") { voice.cancelEnrollment() }
            }
        } else {
            HStack {
                Button(voice.profile == nil ? "Teach Jarvis my voice" : "Re-learn my voice") {
                    model.speaker.stop()
                    voice.startEnrollment()
                    if !voice.running { model.startListening() }
                }
                if voice.profile != nil {
                    Button("Forget my voice", role: .destructive) {
                        voice.removeProfile()
                        model.store.value.voiceLockEnabled = false
                    }
                }
            }
        }
        Hint("A quick on-device check that makes Jarvis ignore other voices and the TV. It is not a security feature and can be fooled, so risky actions still ask you first.")
    }
}

// MARK: Tools

private struct ToolsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var newID = ""
    @State private var newCommand = ""
    @State private var newArgs = ""

    var body: some View {
        Form {
            Section("Built in") {
                Toggle("Web search", isOn: bind(model, \.searchEnabled))
                Toggle("Read web pages", isOn: bind(model, \.webReadEnabled))
                Toggle("Calendar and Reminders", isOn: bind(model, \.calendarEnabled))
                Toggle("Contacts", isOn: bind(model, \.contactsEnabled))
                Toggle("Notes", isOn: bind(model, \.notesEnabled))
                Toggle("Messages (asks before sending)", isOn: bind(model, \.messagesEnabled))
                Toggle("Mail (asks before sending)", isOn: bind(model, \.mailEnabled))
                Toggle("Media, volume, brightness, appearance and Wi-Fi", isOn: bind(model, \.controlEnabled))
                Toggle("Run my Shortcuts", isOn: bind(model, \.shortcutsEnabled))
                Toggle("Disk cleanup and folder organising", isOn: bind(model, \.cleanupEnabled))
                Toggle("Terminal commands (sandboxed)", isOn: bind(model, \.shellEnabled))
                TextField("Folders Jarvis may read (comma separated)", text: Binding(
                    get: { model.store.value.allowedFolders.joined(separator: ", ") },
                    set: { model.store.value.allowedFolders = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
            }
            Section {
                ForEach(Array(model.store.value.mcpServers.enumerated()), id: \.element.id) { i, s in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.id).font(.headline)
                            Text(([s.command] + s.args).joined(separator: " ")).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("On", isOn: Binding(get: { model.store.value.mcpServers[i].enabled }, set: { model.store.value.mcpServers[i].enabled = $0 }))
                        Toggle("Trusted", isOn: Binding(get: { model.store.value.mcpServers[i].trusted }, set: { model.store.value.mcpServers[i].trusted = $0 }))
                            .help("Trusted servers run without asking each time")
                        Button(role: .destructive) { model.store.value.mcpServers.remove(at: i) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                Menu("Add a popular server") {
                    ForEach(MCPServerConfig.presets) { p in
                        Button(p.id) {
                            if !model.store.value.mcpServers.contains(where: { $0.id == p.id }) { model.store.value.mcpServers.append(p) }
                        }
                    }
                }
                HStack {
                    TextField("Name", text: $newID).frame(width: 90)
                    TextField("Command", text: $newCommand).frame(width: 90)
                    TextField("Arguments", text: $newArgs)
                    Button("Add") {
                        let args = newArgs.split(separator: " ").map(String.init)
                        model.store.value.mcpServers.append(MCPServerConfig(id: newID, command: newCommand, args: args))
                        newID = ""; newCommand = ""; newArgs = ""
                    }
                    .disabled(newID.isEmpty || newCommand.isEmpty)
                }
                Hint("Tool servers use the open Model Context Protocol, so Jarvis can use thousands of open-source tools. They need Node.js (npx) or uv (uvx), start the first time they're needed, and ask before each use unless trusted.")
            } header: { Text("Tool servers (MCP)") }
        }
        .formStyle(.grouped)
    }
}

// MARK: Mac

private struct MacTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var telemetry = AppModel.shared.telemetry

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("Model", value: "\(SystemMonitor.chip) · \(SystemMonitor.model)")
                LabeledContent("System", value: SystemMonitor.macOS)
                if let s = telemetry.snapshot {
                    LabeledContent("Storage", value: "\(SystemMonitor.bytes(s.diskFree)) free of \(SystemMonitor.bytes(s.diskTotal))")
                    LabeledContent("Memory", value: "\(SystemMonitor.bytes(Int64(s.memoryUsed))) of \(SystemMonitor.bytes(Int64(s.memoryTotal))), pressure \(s.pressure)")
                    if let b = s.battery {
                        LabeledContent("Battery", value: "\(b.percent)%" + (b.healthPercent.map { ", health \($0)%" } ?? "") + (b.cycles.map { ", \($0) cycles" } ?? ""))
                    }
                }
            }
            Section("Care") {
                Toggle("Warn me about low battery, low storage, memory pressure and overheating", isOn: bind(model, \.healthAlerts))
                Toggle("Show live readings in the main window", isOn: bind(model, \.showTelemetry))
                Hint("Readings are taken only while the window is visible, every two seconds. Warnings are checked every five minutes and repeat at most once an hour.")
            }
            Section("Quick actions") {
                HStack {
                    Button("Check my Mac") { model.submit("How's my Mac doing? Anything I should fix?") }
                    Button("Find space to free") { model.submit("What's taking up my disk space, and what can I safely free?") }
                    Button("Tidy Downloads") { model.submit("Preview how you'd organise my Downloads folder.") }
                }
                Hint("Jarvis always shows what it will remove and asks first. Your files go to the Trash, so you can put them back; only caches and build data that apps rebuild are deleted.")
            }
        }
        .formStyle(.grouped)
        .onAppear { telemetry.setActive(true) }
        .onDisappear { telemetry.setActive(model.windowVisible && model.store.value.showTelemetry) }
    }
}

// MARK: Safety

private struct SafetyTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Confirmations") {
                Toggle("Ask before sending, deleting, buying or entering passwords", isOn: bind(model, \.confirmRisky))
                Hint("After Jarvis reads mail, files, the clipboard or web content, it always asks before risky steps, even if this is off, because that content could try to trick it.")
            }
            Section("Permissions") {
                PermissionsList()
            }
            Section {
                Hint("Press Esc at any time to stop Jarvis. Terminal commands run with no network access and can only write to a scratch folder.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Automations

private struct AutomationsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var prompt = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        Form {
            Section {
                if model.automations.isEmpty {
                    Text("Nothing scheduled yet.").foregroundStyle(.secondary)
                }
                ForEach(model.automations) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.prompt)
                            Text(a.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.memory.removeAutomation(a.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            Section("Add") {
                TextField("Every day, Jarvis should…", text: $prompt)
                DatePicker("At", selection: $time, displayedComponents: .hourAndMinute)
                Button("Add automation") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    model.memory.addAutomation(Automation(id: String(UUID().uuidString.prefix(6)), prompt: prompt,
                                                          hour: c.hour ?? 8, minute: c.minute ?? 0, days: []))
                    prompt = ""
                }
                .disabled(prompt.isEmpty)
                Hint("You can also just say \u{201C}Jarvis, every weekday at 8, summarize my unread mail.\u{201D}")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Memory

private struct MemoryTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("About you") {
                AboutYouForm()
            }
            Section("Memory") {
                Toggle("Remember our conversation, even after Jarvis restarts", isOn: bind(model, \.rememberConversations))
                Toggle("Learn about me from what I say", isOn: bind(model, \.learnAboutMe))
                HStack {
                    Button("Talk with Jarvis again") { model.talkAgain() }
                    Button("Start a new conversation") { model.clearHistory() }
                }
                Hint("Follow-ups like \u{201C}and tomorrow?\u{201D} continue the last topic. Learning uses a tiny Gemini request only when you talk about yourself, and never stores passwords or card numbers.")
            }
            Section {
                if model.facts.isEmpty {
                    Text("Nothing yet. Say \u{201C}Jarvis, remember that…\u{201D} or just tell it about yourself.").foregroundStyle(.secondary)
                }
                ForEach(model.facts, id: \.self) { f in
                    HStack {
                        Text(f)
                        Spacer()
                        Button(role: .destructive) { model.memory.removeFact(f) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("What Jarvis knows")
            } footer: {
                Hint("Stored on this Mac only and sent with your requests so Jarvis can personalise its answers.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Look

private struct LookTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Appearance", selection: bind(model, \.theme)) {
                Text("Dark").tag("dark")
                Text("Light").tag("light")
                Text("Match system").tag("system")
            }
            .pickerStyle(.segmented)
            Picker("Orb", selection: bind(model, \.orbStyle)) {
                Text("Particle sphere").tag("sphere")
                Text("Nucleus").tag("nucleus")
            }
            .pickerStyle(.segmented)
            ColourControls()
            Toggle("Show live Mac readings around the orb", isOn: bind(model, \.showTelemetry))
            Toggle("Reduce motion", isOn: bind(model, \.reduceMotion))
            HStack {
                Spacer()
                OrbView(phase: .listening, accent: model.accent, still: model.store.value.reduceMotion)
                    .frame(width: 150, height: 150)
                Spacer()
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: About

private struct AboutTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Terms accepted", value: model.termsAcceptedOn)
            }
            Section("Terms of use") {
                ScrollView {
                    Text(Terms.text).font(.system(size: 11)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
                HStack(spacing: 14) {
                    Link("Gemini API terms", destination: Links.geminiTerms)
                    Link("Google prohibited use policy", destination: Links.googleUsePolicy)
                    Link("Anthropic usage policy", destination: Links.claudeUsePolicy)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
    }
}
