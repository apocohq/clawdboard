import SwiftUI

/// A single session row with expand/collapse for details.
public struct AgentRow: View {
    public let session: AgentSession
    public let isExpanded: Bool
    public let onToggle: () -> Void
    public var onFocusiTerm2: (() -> Void)?
    public var onFocusVSCode: (() -> Void)?
    public var onDelete: (() -> Void)?

    public init(
        session: AgentSession,
        isExpanded: Bool,
        onToggle: @escaping () -> Void,
        onFocusiTerm2: (() -> Void)? = nil,
        onFocusVSCode: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.session = session
        self.isExpanded = isExpanded
        self.onToggle = onToggle
        self.onFocusiTerm2 = onFocusiTerm2
        self.onFocusVSCode = onFocusVSCode
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                StatusDot(status: session.displayStatus)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.firstPrompt ?? session.projectName)
                        .font(
                            session.firstPrompt != nil
                                ? .system(.body, weight: .medium)
                                : .system(.body, design: .monospaced, weight: .medium)
                        )
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let host = session.remoteHost {
                            Image(systemName: "network")
                                .font(.caption2)
                            Text(host)
                            Text("·")
                        }
                        Text(session.displayStatus.displayLabel)
                            .foregroundStyle(session.displayStatus.displayColor)
                        if session.isHookTracked {
                            Text("·")
                            Text(session.shortModelName)
                            if let branch = session.gitBranch {
                                Text("·")
                                Text(branch)
                            }
                        }
                        if session.displayStatus == .abandoned,
                            let updatedAt = session.updatedAt
                        {
                            Text("·")
                            Text(session.idleSince(updatedAt))
                        }
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

                HStack(spacing: 0) {
                    if let onFocusiTerm2 = onFocusiTerm2 {
                        Button(action: onFocusiTerm2) {
                            Image(systemName: "apple.terminal")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .help("Focus in iTerm2")
                    }

                    if let onFocusVSCode = onFocusVSCode {
                        Button(action: onFocusVSCode) {
                            Image(systemName: "macwindow")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { hovering in
                            if hovering {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .help("Focus in VS Code")
                    }

                    if session.isHookTracked {
                        Text(session.formattedContext)
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(contextColor)
                            .frame(width: 32, alignment: .trailing)
                    } else {
                        Text("—")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }

            }
            .contentShape(Rectangle())
            .onTapGesture { onToggle() }
            .contextMenu {
                if let onDelete = onDelete {
                    Button(role: .destructive) {
                        onDelete()
                    } label: {
                        Label("Delete Session", systemImage: "trash")
                    }
                }
            }
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
        .opacity(session.isHookTracked ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
    }

    private var contextColor: Color {
        guard let pct = session.contextPct else { return .secondary }
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .secondary
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

            if let host = session.remoteHost {
                DetailRow("Host", host)
            }
            DetailRow("Model", session.model ?? "—")
            DetailRow("Branch", session.gitBranch ?? "—")
            DetailRow("Session", session.slug ?? session.sessionId)
            DetailRow("Uptime", session.elapsedTime)
            DetailRow("Path", session.cwd)

            if let subagents = session.subagents, !subagents.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                ForEach(Array(subagents.enumerated()), id: \.element.id) { index, subagent in
                    HStack {
                        Text(index == 0 ? "Agents" : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 60, alignment: .trailing)
                        Circle()
                            .fill(.green)
                            .frame(width: 5, height: 5)
                        Text(subagent.agentType)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                        Spacer()
                        Text(String(subagent.agentId.prefix(8)))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
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

            if let onDelete = onDelete {
                HStack {
                    Spacer()
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help("Delete session")
                }
            }
        }
    }
}
