import Foundation

// MARK: - Agent Status

public enum AgentStatus: String, Codable, CaseIterable {
    case working
    case pendingWaiting = "pending_waiting"
    case needsApproval = "needs_approval"
    case waiting
    case unknown

    /// Sort order for display: needs_approval first (most urgent), then waiting, working, unknown
    public var sortOrder: Int {
        switch self {
        case .needsApproval: return 0
        case .waiting: return 1
        case .pendingWaiting: return 2
        case .working: return 3
        case .unknown: return 4
        }
    }

    public var displayLabel: String {
        switch self {
        case .working: return "Working"
        case .pendingWaiting: return "Working"  // Show as working until debounce completes
        case .needsApproval: return "Needs Approval"
        case .waiting: return "Waiting"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Subagent

/// A subagent spawned by a parent session via the Agent tool.
public struct Subagent: Codable, Equatable, Identifiable {
    public var id: String { agentId }

    public let agentId: String
    public let agentType: String
    public let startedAt: Date?

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentType = "agent_type"
        case startedAt = "started_at"
    }
}

// MARK: - Agent Session

/// Represents a Claude Code agent session.
/// For hook-tracked sessions, this maps directly to the state file JSON.
/// For fallback-discovered sessions, only a subset of fields are populated.
public struct AgentSession: Identifiable, Codable, Equatable {
    public var id: String { sessionId }

    public let sessionId: String
    public let cwd: String
    public var projectName: String
    public var status: AgentStatus
    public var model: String?
    public var gitBranch: String?
    public var slug: String?
    public var costUsd: Double?
    public var contextPct: Double?
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var startedAt: Date?
    public var updatedAt: Date?

    /// Active subagents spawned by this session
    public var subagents: [Subagent]?

    /// PID of the Claude Code process (for liveness checking)
    public var pid: Int?

    /// Whether this session was discovered via hooks (full data) or fallback (limited data)
    public var isHookTracked: Bool

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case projectName = "project_name"
        case status
        case model
        case gitBranch = "git_branch"
        case slug
        case costUsd = "cost_usd"
        case contextPct = "context_pct"
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case subagents
        case pid
        case isHookTracked = "is_hook_tracked"
    }

    public init(
        sessionId: String,
        cwd: String,
        projectName: String,
        status: AgentStatus = .unknown,
        model: String? = nil,
        gitBranch: String? = nil,
        slug: String? = nil,
        costUsd: Double? = nil,
        contextPct: Double? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        subagents: [Subagent]? = nil,
        pid: Int? = nil,
        isHookTracked: Bool = false
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName
        self.status = status
        self.model = model
        self.gitBranch = gitBranch
        self.slug = slug
        self.costUsd = costUsd
        self.contextPct = contextPct
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.pid = pid
        self.isHookTracked = isHookTracked
    }

    /// Formatted cost string like "$1.47"
    public var formattedCost: String {
        guard let cost = costUsd else { return "—" }
        return String(format: "$%.2f", cost)
    }

    /// Formatted context usage like "68%"
    public var formattedContext: String {
        guard let pct = contextPct else { return "—" }
        return String(format: "%.0f%%", pct)
    }

    /// Short model name for display (e.g., "opus" from "claude-opus-4-6")
    public var shortModelName: String {
        guard let model = model else { return "—" }
        if model.contains("opus") { return "Opus" }
        if model.contains("sonnet") { return "Sonnet" }
        if model.contains("haiku") { return "Haiku" }
        return model
    }

    /// Number of active subagents
    public var activeSubagentCount: Int {
        subagents?.count ?? 0
    }

    /// Time elapsed since session started
    public var elapsedTime: String {
        guard let started = startedAt else { return "—" }
        let interval = Date().timeIntervalSince(started)
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        return "\(minutes)m"
    }
}
