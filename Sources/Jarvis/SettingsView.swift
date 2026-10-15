import SwiftUI
import JarvisCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let store = model.store
        TabView {
            Form {
                SecureField("Claude API key", text: Binding(get: { store.claudeKey }, set: { store.claudeKey = $0 }))
                SecureField("Gemini API key", text: Binding(get: { store.geminiKey }, set: { store.geminiKey = $0 }))
                Text("Keys are stored in the macOS Keychain. Chat subscriptions (Claude Pro, Gemini Plus) don't include API access; use keys from console.anthropic.com and aistudio.google.com.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Keys", systemImage: "key") }

            Form {
                Picker("Model", selection: Binding(get: { store.value.modelChoice }, set: { store.value.modelChoice = $0 })) {
                    Text("Auto").tag("auto")
                    ForEach(Catalog.all(store.value)) { Text($0.name).tag($0.id) }
                }
                Toggle("Prefer free Gemini tier for light tasks", isOn: Binding(get: { store.value.preferFreeTier }, set: { store.value.preferFreeTier = $0 }))
                TextField("Gemini fast model id", text: Binding(get: { store.value.geminiFastModel }, set: { store.value.geminiFastModel = $0 }))
                TextField("Gemini pro model id", text: Binding(get: { store.value.geminiProModel }, set: { store.value.geminiProModel = $0 }))
                Stepper("Monthly budget: $\(Int(store.value.monthlyBudgetUSD))", value: Binding(get: { store.value.monthlyBudgetUSD }, set: { store.value.monthlyBudgetUSD = $0 }), in: 1...500, step: 5)
                Stepper(String(format: "Per-task budget: $%.2f", store.value.taskBudgetUSD), value: Binding(get: { store.value.taskBudgetUSD }, set: { store.value.taskBudgetUSD = $0 }), in: 0.05...20, step: 0.25)
                Stepper("Max steps per task: \(store.value.maxSteps)", value: Binding(get: { store.value.maxSteps }, set: { store.value.maxSteps = $0 }), in: 5...100, step: 5)
            }
            .tabItem { Label("Models", systemImage: "cpu") }

            Form {
                Toggle("Ask before sending, deleting, buying or entering credentials", isOn: Binding(get: { store.value.confirmRisky }, set: { store.value.confirmRisky = $0 }))
                Text("Esc stops Jarvis at any time. Grant Accessibility, Screen Recording and Input Monitoring in System Settings → Privacy & Security.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .tabItem { Label("Safety", systemImage: "lock.shield") }

            Form {
                Toggle("Speak replies", isOn: Binding(get: { store.value.speakReplies }, set: { store.value.speakReplies = $0 }))
                Slider(value: Binding(get: { store.value.voiceRate }, set: { store.value.voiceRate = $0 }), in: 0.3...0.7) { Text("Speech rate") }
            }
            .tabItem { Label("Voice", systemImage: "waveform") }

            Form {
                Picker("Accent", selection: Binding(get: { store.value.accent }, set: { store.value.accent = $0 })) {
                    ForEach(["cyan", "purple", "green", "orange"], id: \.self) { Text($0.capitalized).tag($0) }
                }
                Toggle("Reduce motion", isOn: Binding(get: { store.value.reduceMotion }, set: { store.value.reduceMotion = $0 }))
            }
            .tabItem { Label("Look", systemImage: "paintbrush") }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }
}
