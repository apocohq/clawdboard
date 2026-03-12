import SwiftUI

/// Settings form accessible via ⌘, or from the panel.
public struct SettingsView: View {
    @State private var hookStatus: String = "Checking..."
    @State private var isReinstalling = false

    public init() {}

    public var body: some View {
        Form {
            Section("Hook Status") {
                HStack {
                    Text(hookStatus)
                    Spacer()
                    Button("Reinstall Hooks") {
                        reinstallHooks()
                    }
                    .disabled(isReinstalling)
                }
            }

            Section("About") {
                Text("Clawdboard monitors Claude Code sessions via hooks installed in ~/.claude/settings.json")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 200)
        .onAppear { checkHookStatus() }
    }

    private func checkHookStatus() {
        hookStatus = HookManager.shared.isInstalled ? "Installed ✓" : "Not installed"
    }

    private func reinstallHooks() {
        isReinstalling = true
        do {
            try HookManager.shared.install()
            hookStatus = "Reinstalled ✓"
        } catch {
            hookStatus = "Error: \(error.localizedDescription)"
        }
        isReinstalling = false
    }
}
