import SwiftUI

// MARK: - Shared Sessions Content

/// Shared content section used by both panel and detached views:
/// usage limits, divider, and sessions list (or empty state).
public struct SessionsContent: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        if let limits = appState.usageLimits {
            UsageLimitsView(
                limits: limits,
                error: appState.usageLimitsError
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }

        if appState.sessions.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "apple.terminal")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
                Text("No active sessions")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("Start a Claude Code session to see it here")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            SessionsTab()
        }
    }
}

// MARK: - Panel View

/// The main panel shown when clicking the menu bar icon.
/// Header with status summary, sessions list, and footer.
public struct PanelView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @AppStorage("showFloatingWindow") private var showFloatingWindow = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 6)

            SessionsContent()

            Divider()

            footer
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(width: 420)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Clawdboard")
                .font(.headline)

            Spacer()

            // Status pills — compact: dot + count only
            HStack(spacing: 6) {
                if appState.needsApprovalCount > 0 {
                    StatusPill(count: appState.needsApprovalCount, label: "approve", color: .red)
                }
                if appState.waitingCount > 0 {
                    StatusPill(count: appState.waitingCount, label: "your turn", color: .green)
                }
                if appState.workingCount > 0 {
                    StatusPill(count: appState.workingCount, label: "working", color: .blue)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("\(appState.sessions.count) session\(appState.sessions.count == 1 ? "" : "s")")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            Toggle(
                isOn: Binding(
                    get: { showFloatingWindow },
                    set: { newValue in
                        let menuBarPanel = NSApp.keyWindow
                        showFloatingWindow = newValue
                        if newValue {
                            openWindow(id: "main")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                menuBarPanel?.orderOut(nil)
                                for window in NSApp.windows
                                where window.title == "Clawdboard" && window.level == .floating {
                                    window.makeKeyAndOrderFront(nil)
                                }
                                NSApp.activate(ignoringOtherApps: true)
                            }
                        } else {
                            dismissWindow(id: "main")
                        }
                    }
                )
            ) {
                Text("Detach")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)

            if let limits = appState.usageLimits {
                Button {
                    appState.refreshUsageLimits()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Usage updated \(Self.updatedText(limits.updatedAt))")
            }

            Menu {
                SettingsLink {
                    Text("Settings...")
                }
                Button("Reinstall") {
                    try? HookManager.shared.install()
                }
                Divider()
                Button("Quit Clawdboard") {
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        }
    }

    static func updatedText(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

// MARK: - Status Pill

struct StatusPill: View {
    let count: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text("\(count) \(label)")
                .font(.caption2)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(color.opacity(0.12))
        )
    }
}
