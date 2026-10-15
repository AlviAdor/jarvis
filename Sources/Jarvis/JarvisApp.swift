import SwiftUI
import AppKit
import JarvisCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var overlay: OverlayController?
    private var highlighter: HighlightController?

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel.shared
        NSApp.setActivationPolicy(model.store.value.showInDock ? .regular : .accessory)
        overlay = OverlayController(model: model)
        highlighter = HighlightController(model: model)
        model.start()
        if !model.needsOnboarding && !model.store.value.openWindowAtLaunch {
            DispatchQueue.main.async {
                NSApp.windows.filter { $0.identifier?.rawValue.contains("hud") == true }.forEach { $0.close() }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Clicking the Dock icon brings the window back.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppModel.shared.showWindow() }
        return true
    }

    @MainActor
    func application(_ application: NSApplication, open urls: [URL]) {
        urls.forEach { AppModel.shared.handle(url: $0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MCPHub.shared.stopAll()
    }
}

@main
struct JarvisApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Jarvis", id: "hud") {
            RootView()
                .environmentObject(model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 600, height: 800)
        .windowBackgroundDragBehavior(.enabled)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            Button("Show Jarvis") { model.showWindow() }
            Button("Ask Jarvis…") { model.hotkeyPressed() }
                .disabled(model.needsOnboarding)
            Button("How's my Mac?") { model.submit("How's my Mac doing?") }
                .disabled(model.needsOnboarding)
            Button("Stop everything") { model.stopEverything() }
            Divider()
            SettingsLink { Text("Settings…") }
            Button("Quit Jarvis") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: model.phase == .idle ? "waveform.circle" : "waveform.circle.fill")
        }
    }
}
