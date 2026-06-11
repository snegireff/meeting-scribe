import SwiftUI

@main
struct MeetingTranscriberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState()

    var body: some Scene {
        WindowGroup("Meeting Transcriber", id: "main") {
            RootView()
                .environment(state)
                .frame(minWidth: 960, minHeight: 620)
                .task { await state.bootstrap() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                Button("Import Audio or Video…") {
                    state.importPanelRequested.toggle()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .toolbar) {
                Button(state.isMicMuted ? "Unmute Microphone" : "Mute Microphone") {
                    state.setMicMuted(!state.isMicMuted)
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!state.recordingState.isRecording)
            }
        }

        Settings {
            SettingsView()
                .environment(state)
        }

        MenuBarExtra {
            MenuBarMenu(state: state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.menu)
    }
}

/// Keeps the app alive for the menu-bar extra after the main window is closed.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.start()
        NotificationManager.shared.configure()
        // Background services (meeting detection, record-now observer, resuming
        // calendar polling) must come up per process launch, not on main-window
        // appearance — a menu-bar app can be relaunched windowless via state
        // restoration, in which case the window `.task` never fires.
        Task { @MainActor in AppState.shared?.startBackgroundServices() }
    }

    func applicationDidBecomeActive(_ notification: Foundation.Notification) {
        // The app is frontmost here — the only reliable moment to present the
        // calendar TCC prompt. `start()` is guarded so this runs exactly once.
        CalendarMonitor.shared.start()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Foundation.Notification) {
        MCPLocalServer.shared.stop()
        CalendarMonitor.shared.stop()
    }
}
