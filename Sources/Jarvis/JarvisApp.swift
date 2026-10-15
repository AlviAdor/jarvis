import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar app: no Dock icon, runs quietly in the background.
        NSApp.setActivationPolicy(.accessory)
        overlay = OverlayController(model: AppModel.shared)
        AppModel.shared.start()
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppModel.shared.handle(url: $0) }
    }
}

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Jarvis", id: "hud") {
            HUDView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            Button("Show Jarvis") { openWindow(id: "hud"); NSApp.activate(ignoringOtherApps: true) }
            Button("Talk now") { model.pushToTalk() }
            Button("Stop everything") { model.stopEverything() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit Jarvis") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.phase == .idle ? "waveform.circle" : "waveform.circle.fill")
        }
    }
}
