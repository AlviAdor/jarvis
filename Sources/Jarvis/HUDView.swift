import SwiftUI
import JarvisCore

struct HUDView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Text("J.A.R.V.I.S")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(4)
                    .foregroundStyle(model.accent.opacity(0.9))
                Spacer()
                ModelMenu()
                UsageChip(usage: model.usage)
            }

            OrbView(phase: model.phase, accent: model.accent, still: model.store.value.reduceMotion)
                .frame(height: 220)
                .onTapGesture { model.pushToTalk() }

            StatusLine(voice: model.voice, phase: model.phase)

            FeedView()

            HStack(spacing: 10) {
                TextField("Type, say \"Jarvis…\", or press the mic", text: $model.typed)
                    .textFieldStyle(.plain)
                    .padding(10)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit { model.submit(model.typed) }
                Button { model.pushToTalk() } label: {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 16))
                        .frame(width: 40, height: 40)
                        .background(model.accent.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
                Button { model.stopEverything() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                        .frame(width: 40, height: 40)
                        .background(.red.opacity(0.25), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Stop everything (Esc)")
            }
        }
        .padding(20)
        .background(
            ZStack {
                Color(red: 0.03, green: 0.04, blue: 0.07)
                RadialGradient(colors: [model.accent.opacity(0.18), .clear], center: .top, startRadius: 0, endRadius: 420)
            }.ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
    }
}

struct StatusLine: View {
    @ObservedObject var voice: VoiceEngine
    let phase: Phase

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var text: String {
        switch phase {
        case .idle: return voice.running ? "STANDING BY · SAY \"JARVIS\"" : "MICROPHONE OFF"
        case .listening: return voice.partial.isEmpty ? "LISTENING" : voice.partial
        case .thinking: return "THINKING"
        case .acting: return "WORKING ON YOUR SCREEN · ESC TO STOP"
        }
    }
}

private struct FeedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.feed.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("You:") ? Color.white : model.accent.opacity(0.85))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(12)
            }
            .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
            .onChange(of: model.feed.count) { _, n in
                if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
            }
        }
    }
}

private struct ModelMenu: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(["auto", "lite", "flash", "pro"], id: \.self) { c in
                Button(c.capitalized) { model.store.value.modelChoice = c }
            }
        } label: {
            Text(model.store.value.modelChoice.uppercased())
                .font(.system(size: 11, design: .monospaced))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct UsageChip: View {
    @ObservedObject var usage: UsageTracker

    var body: some View {
        Text("\(usage.requests) req · \(usage.tokens / 1000)k tok today")
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}
