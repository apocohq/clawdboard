import SwiftUI

/// Detached floating window variant — same content as PanelView but with
/// actions in the titlebar instead of a footer.
public struct DetachedPanelView: View {
    @AppStorage("showFloatingWindow") private var showFloatingWindow = false
    @Environment(AppState.self) private var appState
    @Environment(\.dismissWindow) private var dismissWindow

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SessionsContent()
        }
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let limits = appState.usageLimits {
                    Button {
                        appState.refreshUsageLimits()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Usage updated \(PanelView.updatedText(limits.updatedAt))")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                settingsMenu
            }
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
}
