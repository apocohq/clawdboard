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
                    let isCollapsed = appState.collapsedGroups.contains(group.key)
                    let displayName =
                        group.key.split(separator: "/").last.map(String.init) ?? group.key

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            appState.toggleGroupCollapsed(group.key)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(
                                systemName: isCollapsed
                                    ? "chevron.right" : "chevron.down"
                            )
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            Text(displayName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                            Spacer()
                            if isCollapsed {
                                Text("\(group.sessions.count)")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, group.key == groups.first?.key ? 0 : 10)

                    if !isCollapsed {
                        ForEach(group.sessions) { session in
                            let lockInfo = appState.ideLockInfo(for: session)
                            AgentRow(
                                session: session,
                                isExpanded: appState.expandedSessionId == session.id,
                                onToggle: {
                                    appState.toggleExpanded(sessionId: session.id)
                                },
                                onFocusiTerm2: session.iterm2SessionId != nil
                                    ? { appState.focusITerm2Session(session) }
                                    : nil,
                                onFocusIDE: session.iterm2SessionId == nil
                                    && lockInfo != nil
                                    ? { appState.focusIDESession(session) }
                                    : nil,
                                ideName: lockInfo?.ideName,
                                onDelete: { appState.deleteSession(session.id) }
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 4)
        }
        .mask(
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 8)
                Color.black
            }
        )
    }
}
