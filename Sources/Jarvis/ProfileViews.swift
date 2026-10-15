import SwiftUI
import AppKit
import JarvisCore

@MainActor
func binding<T>(_ model: AppModel, _ kp: WritableKeyPath<JarvisSettings, T>) -> Binding<T> {
    Binding(get: { model.store.value[keyPath: kp] }, set: { model.store.value[keyPath: kp] = $0 })
}

/// A few questions so Jarvis's answers fit the user's life from day one.
struct AboutYouForm: View {
    @EnvironmentObject var model: AppModel
    static let focusOptions = ["Studies", "Work", "Coding", "Email and messages", "Calendar and reminders",
                               "Keeping my Mac healthy", "Music and media", "News and research", "Writing", "Files and organising"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledField("What should Jarvis call you?") {
                TextField("Your name", text: binding(model, \.userName))
            }
            LabeledField("What do you do?") {
                TextField("For example: computer science student at AIUB", text: binding(model, \.aboutWork))
            }
            LabeledField("Where are you based?") {
                TextField("City and country, for weather, time and places", text: binding(model, \.aboutPlace))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("What do you want help with most?").font(.callout.weight(.medium))
                FlowLayout(spacing: 8) {
                    ForEach(Self.focusOptions, id: \.self) { f in
                        let on = model.store.value.aboutFocus.contains(f)
                        Button {
                            if on { model.store.value.aboutFocus.removeAll { $0 == f } } else { model.store.value.aboutFocus.append(f) }
                        } label: {
                            Text(f)
                                .font(.callout)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(on ? model.accent.opacity(0.3) : Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().stroke(on ? model.accent : Color.primary.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            LabeledField("How should Jarvis answer?") {
                Picker("", selection: binding(model, \.answerStyle)) {
                    Text("Brief").tag("brief")
                    Text("Balanced").tag("balanced")
                    Text("Detailed").tag("detailed")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            LabeledField("Anything else Jarvis should know?") {
                TextEditor(text: binding(model, \.aboutNotes))
                    .font(.body)
                    .frame(height: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Stored only on this Mac and sent with your requests so answers are personal. You can change it any time in Settings, Memory.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.weight(.medium))
            content.textFieldStyle(.roundedBorder)
        }
    }
}

/// Lays children out in rows, wrapping like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += row + spacing; row = 0 }
            x += s.width + spacing
            row = max(row, s.height)
        }
        return CGSize(width: width, height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += row + spacing; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += s.width + spacing
            row = max(row, s.height)
        }
    }
}

/// Light and heavy colours, and whether Jarvis moves between them as work gets harder.
struct ColourControls: View {
    @EnvironmentObject var model: AppModel
    static let heavyPresets = ["#FF3B3B", "#FF6B2C", "#FF2D95", "#B44CFF", "#FFC233"]

    var body: some View {
        Picker("Colour", selection: binding(model, \.colorMode)) {
            Text("Adaptive").tag("adaptive")
            Text("Fixed").tag("fixed")
        }
        .pickerStyle(.segmented)
        swatches(model.store.value.colorMode == "adaptive" ? "Light work" : "Colour", presets: AccentPresets.all, kp: \.accentHex)
        if model.store.value.colorMode == "adaptive" {
            swatches("Heavy work", presets: Self.heavyPresets, kp: \.heavyAccentHex)
            VStack(alignment: .leading, spacing: 6) {
                LinearGradient(colors: [Color(hex: model.store.value.accentHex), Color(hex: model.store.value.heavyAccentHex)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 8)
                    .clipShape(Capsule())
                HStack {
                    Text("Chat and quick answers").font(.caption2)
                    Spacer()
                    Text("Web and tools").font(.caption2)
                    Spacer()
                    Text("Screen control, deep thinking, Mac under strain").font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
            Button("Preview heavy work") {
                model.setWorkload(1)
                model.setWorkload(0, after: 2.5)
            }
        }
    }

    private func swatches(_ title: String, presets: [String], kp: WritableKeyPath<JarvisSettings, String>) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(presets, id: \.self) { hex in
                Button { model.store.value[keyPath: kp] = hex } label: {
                    Circle()
                        .fill(Color(hex: hex))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(.primary, lineWidth: model.store.value[keyPath: kp] == hex ? 2 : 0))
                }
                .buttonStyle(.plain)
            }
            ColorPicker("", selection: Binding(get: { Color(hex: model.store.value[keyPath: kp]) },
                                               set: { model.store.value[keyPath: kp] = $0.hex }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}

/// Getting a smarter local model: install Ollama, start it, and download a model, all from here.
struct OllamaSetup: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(model.ollamaModels.isEmpty ? Color.orange : Color.green).frame(width: 8, height: 8)
                Text(status).font(.callout)
                Spacer()
                if model.ollamaModels.isEmpty, model.ollamaBusy == nil {
                    Button(LocalBrain.ollamaInstalled ? "Start Ollama" : "Install Ollama") { Task { await model.setUpOllama() } }
                }
            }
            if let busy = model.ollamaBusy {
                HStack(spacing: 8) {
                    if let p = model.pullProgress { ProgressView(value: p).frame(width: 140) } else { ProgressView().controlSize(.small) }
                    Text(busy).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            ForEach(LocalBrain.suggested, id: \.name) { m in
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).font(.system(.callout, design: .monospaced))
                        Text("\(m.label) · \(m.size)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.ollamaModels.contains(where: { $0.hasPrefix(m.name) }) {
                        if model.store.value.ollamaModel == m.name {
                            Label("In use", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                        } else {
                            Button("Use") { model.store.value.ollamaModel = m.name }
                        }
                    } else {
                        Button("Download") { Task { await model.downloadModel(m.name) } }
                            .disabled(model.ollamaBusy != nil)
                    }
                }
            }
            Text("Ollama is free and open source (MIT). It runs models entirely on this Mac: no API key, no account, nothing sent online. With 16 GB of memory, qwen3:8b is the best balance.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task { model.ollamaModels = await LocalBrain.shared.ollamaModels(fresh: true) }
    }

    private var status: String {
        if !model.ollamaModels.isEmpty { return "Ollama is running with \(model.ollamaModels.count) model\(model.ollamaModels.count == 1 ? "" : "s")" }
        return LocalBrain.ollamaInstalled ? "Ollama is installed but not running" : "Ollama isn't installed"
    }
}
