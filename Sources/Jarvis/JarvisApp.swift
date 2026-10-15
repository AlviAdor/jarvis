import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Jarvis", id: "hud") {
            HUDView()
                .environmentObject(model)
                .frame(minWidth: 520, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra("Jarvis", systemImage: "waveform.circle") {
            Button("Show Jarvis") { openWindow(id: "hud"); NSApp.activate(ignoringOtherApps: true) }
            Button("Listen") { model.toggleListening() }
            Button("Stop everything") { model.stopEverything() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}
