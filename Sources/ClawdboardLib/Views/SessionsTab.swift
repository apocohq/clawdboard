import SwiftUI

/// Main sessions list grouped by GitHub repo (or project name for local repos).
public struct SessionsTab: View {
    @Environment(AppState.self) private var appState

    public init() {}

    /// Sessions grouped and sorted by urgency within each group.
    private var groupedSessions: [(key: String, sessions: [AgentSession])] {
        let dict = Dictionary(grouping: appState.sortedSessions) { session in
            session.githubRepo ?? session.projectName
        }
        return
            dict
            .map { (key: $0.key, sessions: $0.value) }
            .sorted { a, b in
                let aOrder = a.sessions.first?.displayStatus.sortOrder ?? 99
                let bOrder = b.sessions.first?.displayStatus.sortOrder ?? 99
                if aOrder != bOrder { return aOrder < bOrder }
                return a.key < b.key
            }
    }

    public var body: some View {
        let groups = groupedSessions
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(groups, id: \.key) { group in
                    Text(group.key)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.horizontal, 8)
                        .padding(.top, group.key == groups.first?.key ? 0 : 6)
                    ForEach(group.sessions) { session in
                        AgentRow(
                            session: session,
                            isExpanded: appState.expandedSessionId == session.id,
                            onToggle: { appState.toggleExpanded(sessionId: session.id) }
                        )
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
