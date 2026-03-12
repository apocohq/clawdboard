import SwiftUI

/// Main sessions list sorted by urgency.
public struct SessionsTab: View {
    @Environment(AppState.self) private var appState

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(appState.sortedSessions) { session in
                    AgentRow(
                        session: session,
                        isExpanded: appState.expandedSessionId == session.id,
                        onToggle: { appState.toggleExpanded(sessionId: session.id) }
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
    }
}
