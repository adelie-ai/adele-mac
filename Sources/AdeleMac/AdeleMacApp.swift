import AppKit
import SwiftUI

// When launched as a bare SwiftPM executable (not a .app bundle), macOS starts
// the process as a non-activating accessory: the window shows but never becomes
// key, so keyboard focus stays with the launching terminal. Forcing a regular
// activation policy and activating on launch fixes focus. (A proper .app bundle —
// see scripts/run-app.sh — is the robust path and avoids this entirely.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct AdeleMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .frame(minWidth: 720, minHeight: 480)
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Conversation") { model.newConversation() }
                    .keyboardShortcut("n", modifiers: .command)
                    .disabled(!model.connected)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showScratchpad ? "Hide Scratchpad" : "Show Scratchpad") {
                    model.showScratchpad.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!model.connected)
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
