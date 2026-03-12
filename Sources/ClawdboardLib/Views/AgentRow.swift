import SwiftUI

/// A single session row with expand/collapse for details.
public struct AgentRow: View {
    public let session: AgentSession
    public let isExpanded: Bool
    public let onToggle: () -> Void

    public init(session: AgentSession, isExpanded: Bool, onToggle: @escaping () -> Void) {
        self.session = session
        self.isExpanded = isExpanded
        self.onToggle = onToggle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                StatusDot(status: session.displayStatus)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.projectName)
                        .font(.system(.body, design: .monospaced, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if session.isHookTracked {
                            Text(session.shortModelName)
                            if let branch = session.gitBranch {
                                Text("·")
                                Text(branch)
                            }
                            Text("·")
                        }
                        Text(session.displayStatus.displayLabel)
                        if session.activeSubagentCount > 0 {
                            Text("·")
                            Text(
                                "\(session.activeSubagentCount) subagent\(session.activeSubagentCount == 1 ? "" : "s")"
                            )
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if session.isHookTracked {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text(session.formattedCost)
                            .font(.caption.monospacedDigit())
                        Text(session.formattedContext)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)

            // Expanded detail section
            if isExpanded {
                expandedDetails
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5))
        )
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
                .padding(.vertical, 2)

            if let pct = session.contextPct {
                HStack(spacing: 6) {
                    Text("Context")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    ContextBar(percentage: pct)
                    Text(session.formattedContext)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            DetailRow("Model", session.model ?? "—")
            DetailRow("Branch", session.gitBranch ?? "—")
            DetailRow("Cost", session.formattedCost)
            DetailRow("Session", session.slug ?? session.sessionId)
            DetailRow("Uptime", session.elapsedTime)
            DetailRow("Path", session.cwd)

            if let subagents = session.subagents, !subagents.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                Text("Subagents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(subagents) { subagent in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                        Text(subagent.agentType)
                            .font(.caption)
                        Spacer()
                        Text(subagent.agentId.prefix(8))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.leading, 66)
                }
            }

            if !session.isHookTracked {
                HStack {
                    Spacer()
                    Text("Restart session for full tracking")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Spacer()
                }
                .padding(.top, 2)
            }
        }
    }
}
