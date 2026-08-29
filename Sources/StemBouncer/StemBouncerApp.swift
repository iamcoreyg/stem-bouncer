import AppKit
import SwiftUI

@main
struct StemBouncerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .frame(minWidth: 1_040, minHeight: 700)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Session") {
                Button("Discover Tracks") { Task { await model.discoverTracks() } }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button(model.isRunning ? "Pause Run" : "Start Run") {
                    model.isRunning ? model.pauseRun(reason: "Paused by user") : model.showPreflight()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(model.groups.isEmpty)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(minWidth: 520, minHeight: 420)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }
}
