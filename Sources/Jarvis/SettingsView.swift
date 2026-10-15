import SwiftUI
import JarvisCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            KeysTab().tabItem { Label("Keys", systemImage: "key") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            VoiceTab().tabItem { Label("Voice", systemImage: "waveform") }
            SafetyTab().tabItem { Label("Safety", systemImage: "lock.shield") }
            AutomationsTab().tabItem { Label("Automations", systemImage: "clock") }
            MemoryTab().tabItem { Label("Memory", systemImage: "brain") }
            LookTab().tabItem { Label("Look", systemImage: "paintbrush") }
        }
        .padding(20)
        .frame(width: 580, height: 420)
    }
}

private func bind<T>(_ model: AppModel, _ kp: WritableKeyPath<JarvisSettings, T>) -> Binding<T> {
    Binding(get: { model.store.value[keyPath: kp] }, set: { model.store.value[keyPath: kp] = $0 })
}

private struct KeysTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            SecureField("Gemini API key", text: Binding(get: { model.store.geminiKey }, set: { model.store.geminiKey = $0 }))
            SecureField("Claude API key (optional)", text: Binding(get: { model.store.claudeKey }, set: { model.store.claudeKey = $0 }))
            Toggle("Use Claude first when a key is set", isOn: bind(model, \.claudeEnabled))
            TextField("Your name", text: bind(model, \.userName))
            Text("Keys live in the macOS Keychain. If Claude fails for any reason, such as no credits, Jarvis switches to Gemini automatically. Get a free Gemini key at aistudio.google.com. Chat subscriptions (Claude Pro, Gemini Plus) don't include API access.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

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
            Picker("Mode", selection: bind(model, \.modelChoice)) {
                Text("Auto (cheapest model that fits)").tag("auto")
                Text("Always lite").tag("lite")
                Text("Always flash").tag("flash")
                Text("Always pro").tag("pro")
            }
            picker("Gemini lite (chat, routing)", \.liteModel)
            picker("Gemini flash (screen, web)", \.flashModel)
            picker("Gemini pro (hard tasks)", \.proModel)
            Button("Refresh model list from Google") { model.refreshModels() }
            TextField("Claude lite model", text: bind(model, \.claudeLiteModel))
            TextField("Claude flash-tier model", text: bind(model, \.claudeFlashModel))
            TextField("Claude pro-tier model", text: bind(model, \.claudeProModel))
            Stepper("Daily request cap: \(model.store.value.dailyRequestCap)", value: bind(model, \.dailyRequestCap), in: 20...5000, step: 20)
            Stepper("Max steps per screen task: \(model.store.value.maxSteps)", value: bind(model, \.maxSteps), in: 5...100, step: 5)
        }
    }
}

private struct VoiceTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Listen for the wake word", isOn: bind(model, \.wakeWordEnabled))
            TextField("Wake word", text: bind(model, \.wakeWord))
            Slider(value: bind(model, \.micThreshold), in: 0.005...0.08) { Text("Mic sensitivity (right = needs louder speech)") }
            Toggle("Speak replies", isOn: bind(model, \.speakReplies))
            Slider(value: bind(model, \.voiceRate), in: 0.3...0.7) { Text("Speech rate") }
            Toggle("Open at login", isOn: bind(model, \.launchAtLogin))
            Text("Speech is recognized on this Mac when the on-device model is available. Nothing is sent anywhere until you say the wake word and ask something. For Siri: create a Shortcut named \"Ask Jarvis\" that opens the URL jarvis://listen, then say \"Hey Siri, Ask Jarvis\".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct SafetyTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Toggle("Ask before sending, deleting, buying or entering credentials", isOn: bind(model, \.confirmRisky))
            Toggle("Allow sandboxed shell commands", isOn: bind(model, \.shellEnabled))
            Toggle("Allow Mail access", isOn: bind(model, \.mailEnabled))
            TextField("Readable folders (comma separated)", text: Binding(
                get: { model.store.value.allowedFolders.joined(separator: ", ") },
                set: { model.store.value.allowedFolders = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
            ))
            Text("Shell commands run with no network, no writes outside a scratch folder, and no access to ~/.ssh or your keychains. Esc stops Jarvis at any time. Grant Accessibility, Screen Recording and Input Monitoring in System Settings, Privacy and Security.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AutomationsTab: View {
    @EnvironmentObject var model: AppModel
    @State private var prompt = ""
    @State private var time = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            List {
                ForEach(model.automations) { a in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(a.prompt)
                            Text(a.label).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.memory.removeAutomation(a.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("Every day, Jarvis should…", text: $prompt)
                DatePicker("", selection: $time, displayedComponents: .hourAndMinute).labelsHidden()
                Button("Add") {
                    let c = Calendar.current.dateComponents([.hour, .minute], from: time)
                    model.memory.addAutomation(Automation(id: String(UUID().uuidString.prefix(6)), prompt: prompt,
                                                          hour: c.hour ?? 8, minute: c.minute ?? 0, days: []))
                    prompt = ""
                }
                .disabled(prompt.isEmpty)
            }
            Text("You can also just say \"Jarvis, every weekday at 8 summarize my unread mail\".")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct MemoryTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.facts, id: \.self) { f in
                HStack {
                    Text(f)
                    Spacer()
                    Button(role: .destructive) { model.memory.removeFact(f) } label: { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                }
            }
            if model.facts.isEmpty { Text("Nothing yet. Say \"Jarvis, remember that…\".").foregroundStyle(.secondary) }
        }
    }
}

private struct LookTab: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Picker("Accent", selection: bind(model, \.accent)) {
                ForEach(["cyan", "purple", "green", "orange"], id: \.self) { Text($0.capitalized).tag($0) }
            }
            Toggle("Show the floating overlay", isOn: bind(model, \.overlayEnabled))
            Toggle("Reduce motion", isOn: bind(model, \.reduceMotion))
        }
    }
}
