import SwiftUI

/// Settings form accessible via ⌘, or from the panel.
public struct SettingsView: View {
    @State private var hookStatus: String = "Checking..."
    @State private var isReinstalling = false
    @AppStorage("useRedYellowMode") private var useRedYellowMode = true

    public init() {}

    public var body: some View {
        Form {
            Section("Appearance") {
                Toggle(isOn: $useRedYellowMode) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Two-color attention mode")
                        Text(
                            useRedYellowMode
                                ? "Red = needs approval, Yellow = waiting"
                                : "Yellow = needs attention"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

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
        .frame(width: 400, height: 260)
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
