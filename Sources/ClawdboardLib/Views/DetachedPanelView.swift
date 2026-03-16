import SwiftUI

/// Detached floating window variant — same content as PanelView but with
/// actions in the titlebar instead of a footer.
public struct DetachedPanelView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("showFloatingWindow") private var showFloatingWindow = false
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            usageLimitsSection
            Divider()
            contentSection
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                settingsMenu
            }
        }
    }

    @ViewBuilder
    private var usageLimitsSection: some View {
        if let limits = appState.usageLimits {
            UsageLimitsView(
                limits: limits,
                error: appState.usageLimitsError,
                onRefresh: { appState.refreshUsageLimits() }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    @ViewBuilder
    private var contentSection: some View {
        if appState.sessions.isEmpty {
            emptyState
        } else {
            SessionsTab()
        }
    }

    private var settingsMenu: some View {
        Menu {
            SettingsLink {
                Text("Settings...")
            }
            Button("Reinstall") {
                try? HookManager.shared.install()
            }
            Divider()
            Button("Attach to Menu Bar") {
                showFloatingWindow = false
                dismissWindow(id: "main")
            }
            Divider()
            Button("Quit Clawdboard") {
                NSApplication.shared.terminate(nil)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal")
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
    }
}
