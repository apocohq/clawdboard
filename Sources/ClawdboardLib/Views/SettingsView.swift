import SwiftUI

/// Settings form accessible via ⌘, or from the panel.
public struct SettingsView: View {
    @State private var hookStatus: String = "Checking..."
    @State private var isReinstalling = false
    @State private var sshConfigHosts: [SSHConfigHost] = []
    @AppStorage("useRedYellowMode") private var useRedYellowMode = true
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            remoteHostsTab
                .tabItem { Label("Remote Hosts", systemImage: "network") }
        }
        .frame(width: 500, height: 400)
        .background(.ultraThinMaterial)
        .onAppear { checkHookStatus() }
    }

    // MARK: - General Tab

    private var generalTab: some View {
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
                Text(
                    "Clawdboard monitors Claude Code sessions via hooks installed in ~/.claude/settings.json"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    // MARK: - Remote Hosts Tab

    private var remoteHostsTab: some View {
        Form {
            Section {
                if appState.remoteHosts.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "network.slash")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text("No remote hosts configured")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("Add a remote machine to monitor its Claude Code sessions via SSH")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                } else {
                    ForEach(Array(appState.remoteHosts.enumerated()), id: \.element.id) {
                        index, host in
                        RemoteHostRow(
                            host: host,
                            onUpdate: { updated in
                                appState.updateRemoteHost(at: index, with: updated)
                            },
                            onRemove: {
                                appState.removeRemoteHost(at: index)
                            }
                        )
                    }
                }
            } header: {
                HStack {
                    Text("SSH Hosts")
                    Spacer()
                    addHostMenu
                }
            } footer: {
                Text(
                    "Uses your ~/.ssh/config and ssh-agent for authentication. Ensure key-based auth is configured."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .onAppear { sshConfigHosts = parseSSHConfig() }
    }

    private var addHostMenu: some View {
        let alreadyAdded = Set(appState.remoteHosts.map(\.host))
        let available = sshConfigHosts.filter { !alreadyAdded.contains($0.alias) }

        return Menu {
            Button("New Host...") {
                appState.addRemoteHost()
            }

            if !available.isEmpty {
                Divider()

                Section("From ~/.ssh/config") {
                    ForEach(available) { entry in
                        Button {
                            appState.addRemoteHost(
                                host: entry.alias,
                                label: entry.hostname != nil ? entry.displayString : ""
                            )
                        } label: {
                            VStack(alignment: .leading) {
                                Text(entry.alias)
                                if let hostname = entry.hostname {
                                    Text(
                                        [entry.user, hostname]
                                            .compactMap { $0 }
                                            .joined(separator: "@")
                                    )
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Helpers

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

// MARK: - Remote Host Row

struct RemoteHostRow: View {
    let host: RemoteHost
    let onUpdate: (RemoteHost) -> Void
    let onRemove: () -> Void

    @State private var isEditing: Bool
    @State private var editHost: String
    @State private var editLabel: String
    @State private var isInstalling = false
    @State private var isChecking = false
    @State private var installMessage: String?

    init(host: RemoteHost, onUpdate: @escaping (RemoteHost) -> Void, onRemove: @escaping () -> Void) {
        self.host = host
        self.onUpdate = onUpdate
        self.onRemove = onRemove
        // Start in edit mode if host is empty (just added)
        let isNew = host.host.isEmpty
        _isEditing = State(initialValue: isNew)
        _editHost = State(initialValue: host.host)
        _editLabel = State(initialValue: host.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isEditing {
                editingView
            } else {
                displayView
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Display Mode

    private var displayView: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { host.isEnabled },
                        set: { enabled in
                            var updated = host
                            updated.isEnabled = enabled
                            onUpdate(updated)
                        }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

                VStack(alignment: .leading, spacing: 1) {
                    Text(host.displayLabel)
                        .font(.system(.body, design: .monospaced))
                    if !host.label.isEmpty {
                        Text(host.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                hookStatusBadge

                HStack(spacing: 4) {
                    Button {
                        editHost = host.host
                        editLabel = host.label
                        isEditing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.borderless)

                    Button(role: .destructive) {
                        onRemove()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            HStack(spacing: 8) {
                Button("Check Hooks") {
                    checkHooks()
                }
                .controlSize(.small)
                .disabled(isChecking || host.host.isEmpty)

                Button("Install Hooks") {
                    installHooks()
                }
                .controlSize(.small)
                .disabled(isInstalling || host.host.isEmpty)

                if let message = installMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(
                            message.contains("Error") || message.contains("Failed")
                                ? .red : .green)
                }
            }
            .padding(.leading, 42)
        }
    }

    // MARK: - Editing Mode

    private var editingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH Host")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("user@hostname", text: $editHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Label")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Optional display name", text: $editLabel)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    if host.host.isEmpty {
                        onRemove()
                    } else {
                        isEditing = false
                    }
                }
                .controlSize(.small)

                Button("Save") {
                    var updated = host
                    updated.host = editHost
                    updated.label = editLabel
                    onUpdate(updated)
                    isEditing = false
                }
                .controlSize(.small)
                .disabled(editHost.isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    // MARK: - Hook Status Badge

    @ViewBuilder
    private var hookStatusBadge: some View {
        switch host.hookStatus {
        case .installed:
            Label("Hooks OK", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .notInstalled:
            Label("No Hooks", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.orange)
        case .error:
            Label("SSH Error", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.red)
        case .unknown:
            Label("Unchecked", systemImage: "questionmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Actions

    private func checkHooks() {
        isChecking = true
        installMessage = nil
        RemoteSessionWatcher.checkRemoteHooks(host: host.host) { status in
            var updated = host
            updated.hookStatus = status
            onUpdate(updated)
            isChecking = false
        }
    }

    private func installHooks() {
        isInstalling = true
        installMessage = nil
        RemoteSessionWatcher.installRemoteHooks(host: host.host) { result in
            switch result {
            case .success:
                installMessage = "Hooks installed!"
                var updated = host
                updated.hookStatus = .installed
                onUpdate(updated)
            case .failure(let error):
                installMessage = "Error: \(error.localizedDescription)"
                var updated = host
                updated.hookStatus = .error
                onUpdate(updated)
            }
            isInstalling = false
        }
    }
}
