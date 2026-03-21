import AppKit
import SwiftUI

/// A single session row with expand/collapse for details.
public struct AgentRow: View {
    public let session: AgentSession
    public let isExpanded: Bool
    public let onActivate: () -> Void
    public let onToggle: () -> Void
    public var onFocusiTerm2: (() -> Void)?
    public var onFocusIDE: (() -> Void)?
    public var ideName: String?
    public var onDelete: (() -> Void)?

    @State private var isHovered = false

    public init(
        session: AgentSession,
        isExpanded: Bool,
        onActivate: @escaping () -> Void,
        onToggle: @escaping () -> Void,
        onFocusiTerm2: (() -> Void)? = nil,
        onFocusIDE: (() -> Void)? = nil,
        ideName: String? = nil,
        onDelete: (() -> Void)? = nil
    ) {
        self.session = session
        self.isExpanded = isExpanded
        self.onActivate = onActivate
        self.onToggle = onToggle
        self.onFocusiTerm2 = onFocusiTerm2
        self.onFocusIDE = onFocusIDE
        self.ideName = ideName
        self.onDelete = onDelete
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 8) {
                StatusDot(status: session.displayStatus)

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayTitle)
                        .font(.system(.body, weight: .medium))
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        if let host = session.remoteHost {
                            Image(systemName: "network")
                                .font(.caption2)
                            Text(host)
                            Text("·")
                        }
                        Text(session.displayStatus.displayLabel)
                        if session.isHookTracked {
                            if let branch = session.gitBranch {
                                Text("·")
                                if let compareUrl = session.compareUrl,
                                    let url = URL(string: compareUrl)
                                {
                                    Link(destination: url) {
                                        HStack(spacing: 2) {
                                            Image(systemName: "arrow.triangle.pull")
                                                .font(.caption2)
                                            Text(branch)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .layoutPriority(-1)
                                    .pointingHandCursor()
                                } else {
                                    Text(branch)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .layoutPriority(-1)
                                }
                            }
                            if let diffStats = session.formattedDiffStats {
                                Text("·")
                                DiffStatsLabel(stats: diffStats)
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

                Button(action: onToggle) {
                    Image(
                        systemName: isExpanded
                            ? "chevron.down" : "chevron.right"
                    )
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse" : "Expand")

            }
            .contentShape(Rectangle())
            .pointingHandCursor()
            .onTapGesture { onActivate() }
            .contextMenu {
                if let onFocusiTerm2 = onFocusiTerm2 {
                    Button {
                        onFocusiTerm2()
                    } label: {
                        Label("Focus in iTerm2", systemImage: "apple.terminal")
                    }
                }
                if let onFocusIDE = onFocusIDE {
                    Button {
                        onFocusIDE()
                    } label: {
                        Label(
                            "Focus in \(ideName ?? "VS Code")",
                            systemImage: "macwindow"
                        )
                    }
                }
                if onFocusiTerm2 != nil || onFocusIDE != nil {
                    Divider()
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        session.sessionId, forType: .string
                    )
                } label: {
                    Label("Copy Session ID", systemImage: "doc.on.doc")
                }
                if let onDelete = onDelete {
                    Divider()
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
                .fill(.quaternary.opacity(isHovered ? 0.8 : 0.5))
        )
        .onHover { isHovered = $0 }
        .opacity(session.isHookTracked ? 1.0 : 0.6)
        .animation(.easeInOut(duration: 0.15), value: isExpanded)
        .animation(.easeInOut(duration: 0.1), value: isHovered)
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
            if let diffStats = session.formattedDiffStats {
                HStack {
                    Text("Changes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 60, alignment: .trailing)
                    DiffStatsLabel(stats: diffStats)
                        .font(.caption.monospaced())
                }
            }
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
                            .fill(.blue)
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
                    .pointingHandCursor()
                    .help("Delete session")
                }
            }
        }
    }
}

// MARK: - Diff Stats Label

/// Renders diff stats like "+120 −47" with green for additions and red for deletions.
struct DiffStatsLabel: View {
    let stats: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(parts, id: \.self) { part in
                Text(part)
                    .foregroundStyle(part.hasPrefix("+") ? .green : .red)
            }
        }
        .font(.caption.monospacedDigit())
    }

    private var parts: [String] {
        stats.split(separator: " ").map(String.init)
    }
}
