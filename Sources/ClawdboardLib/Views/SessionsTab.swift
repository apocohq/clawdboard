import SwiftUI

/// Main sessions list grouped by GitHub repo (or project name for local repos).
public struct SessionsTab: View {
    @Environment(AppState.self) private var appState

    public init() {}

    /// Sessions grouped alphabetically (stable order).
    private var groupedSessions: [(key: String, sessions: [AgentSession])] {
        let dict = Dictionary(grouping: appState.sortedSessions) { session in
            session.githubRepo ?? session.projectName
        }
        return
            dict
            .map { (key: $0.key, sessions: $0.value) }
            .sorted { $0.key < $1.key }
    }

    public var body: some View {
        let groups = groupedSessions
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.key) { group in
                    Text(group.key)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 4)
                        .padding(.top, group.key == groups.first?.key ? 0 : 6)
                    ForEach(group.sessions) { session in
                        AgentRow(
                            session: session,
                            isExpanded: appState.expandedSessionId == session.id,
                            onToggle: { appState.toggleExpanded(sessionId: session.id) },
                            onFocusiTerm2: session.iterm2SessionId != nil
                                ? { appState.focusITerm2Session(session) }
                                : nil
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
