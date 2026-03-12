import AppKit
import ClawdboardLib
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            Self.checkAndInstallHooks()
        }
    }

    static func checkAndInstallHooks() {
        let hookManager = HookManager.shared

        // Always update hook script (idempotent)
        try? hookManager.installHookScript()

        // If all expected hooks are registered, nothing more to do
        guard !hookManager.isInstalled else { return }

        let alert = NSAlert()
        alert.messageText = "Install Session Tracking Hooks?"
        alert.informativeText = """
            Clawdboard needs to add hooks to your Claude Code settings \
            (~/.claude/settings.json) to track session status in real-time.

            This enables:
            • Detecting when sessions start and end
            • Knowing when a session is waiting for your input
            • Tracking context usage and cost per session

            Your existing Claude settings will be preserved. \
            You can remove hooks anytime from Clawdboard settings.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Not Now")

        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            do {
                try hookManager.installHooksInSettings()
            } catch {
                let errorAlert = NSAlert()
                errorAlert.messageText = "Hook Installation Failed"
                errorAlert.informativeText = error.localizedDescription
                errorAlert.alertStyle = .warning
                errorAlert.runModal()
            }
        }
    }
}

@main
struct ClawdboardApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environment(appState)
                .onAppear { appState.start() }
                .onDisappear { appState.stop() }
        } label: {
            MenuBarLabel(appState: appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Menu bar icon with session count and status indicator.
struct MenuBarLabel: View {
    let appState: AppState

    var body: some View {
        let total = appState.sessions.count
        let approval = appState.needsApprovalCount
        let waiting = appState.waitingCount

        HStack(spacing: 3) {
            Image(systemName: "terminal.fill")
            if total > 0 {
                Text("\(total)")
                    .font(.caption2)
            }
            if approval > 0 {
                Circle()
                    .fill(.red)
                    .frame(width: 6, height: 6)
            } else if waiting > 0 {
                Circle()
                    .fill(.orange)
                    .frame(width: 6, height: 6)
            }
        }
    }
}
