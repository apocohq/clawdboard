import Foundation

// MARK: - IDE Lock Info

/// Data from a ~/.claude/ide/<pid>.lock file identifying an IDE window.
public struct IdeLockInfo: Codable {
    public let pid: Int
    public let workspaceFolders: [String]
    public let ideName: String
    public let transport: String?
    public let runningInWindows: Bool?
    public let authToken: String?
}

// MARK: - Remote Host

/// A remote machine to monitor for Claude Code sessions via SSH.
public struct RemoteHost: Identifiable, Codable, Equatable {
    public var id: String { host }

    /// SSH destination (e.g. "user@hostname" or just "hostname" if user matches)
    public var host: String

    /// Display label (defaults to host if empty)
    public var label: String

    /// Whether this host is enabled for polling
    public var isEnabled: Bool

    /// Polling interval in seconds
    public var pollInterval: TimeInterval

    /// Hook installation status
    public var hookStatus: RemoteHookStatus

    public init(
        host: String,
        label: String = "",
        isEnabled: Bool = true,
        pollInterval: TimeInterval = 10,
        hookStatus: RemoteHookStatus = .unknown
    ) {
        self.host = host
        self.label = label
        self.isEnabled = isEnabled
        self.pollInterval = pollInterval
        self.hookStatus = hookStatus
    }

    public var displayLabel: String {
        label.isEmpty ? host : label
    }
}

// MARK: - SSH Config Parser

/// A host entry parsed from ~/.ssh/config.
public struct SSHConfigHost: Identifiable, Equatable {
    public var id: String { alias }

    /// The Host alias (e.g. "myvm")
    public let alias: String

    /// The HostName if specified, otherwise nil
    public let hostname: String?

    /// The User if specified, otherwise nil
    public let user: String?

    /// Display string like "user@hostname" or just the alias
    public var displayString: String {
        if let user = user, let hostname = hostname {
            return "\(user)@\(hostname)"
        }
        if let hostname = hostname {
            return hostname
        }
        return alias
    }
}

/// Parses ~/.ssh/config for Host entries, skipping wildcards and defaults.
public func parseSSHConfig() -> [SSHConfigHost] {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config")
    guard let contents = try? String(contentsOf: configPath, encoding: .utf8) else {
        return []
    }

    var hosts: [SSHConfigHost] = []
    var currentAlias: String?
    var currentHostname: String?
    var currentUser: String?

    for line in contents.components(separatedBy: .newlines) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

        let parts = trimmed.split(separator: " ", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { continue }

        let key = parts[0].lowercased()
        let value = parts[1]

        if key == "host" {
            // Save previous entry
            if let alias = currentAlias, !alias.contains("*"), alias != "*" {
                hosts.append(
                    SSHConfigHost(
                        alias: alias, hostname: currentHostname, user: currentUser))
            }
            currentAlias = value
            currentHostname = nil
            currentUser = nil
        } else if key == "hostname" {
            currentHostname = value
        } else if key == "user" {
            currentUser = value
        }
    }

    // Save last entry
    if let alias = currentAlias, !alias.contains("*"), alias != "*" {
        hosts.append(
            SSHConfigHost(
                alias: alias, hostname: currentHostname, user: currentUser))
    }

    // Filter out well-known non-machine hosts (git forges, package registries, etc.)
    let excludedPatterns = [
        "github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com",
        "vs-ssh.visualstudio.com", "source.developers.google.com",
        "git-codecommit", "heroku.com", "codeberg.org", "sr.ht",
    ]
    return hosts.filter { entry in
        let name = (entry.hostname ?? entry.alias).lowercased()
        return !excludedPatterns.contains { name.contains($0) }
    }
}

public enum RemoteHookStatus: String, Codable {
    case unknown
    case installed
    case notInstalled = "not_installed"
    case error
}

// MARK: - Agent Status

public enum AgentStatus: String, Codable, CaseIterable {
    case working
    case pendingWaiting = "pending_waiting"
    case needsApproval = "needs_approval"
    case waiting
    case unknown
    case abandoned

    /// Sort order for display: needs_approval first (most urgent), then waiting, working, unknown, abandoned
    public var sortOrder: Int {
        switch self {
        case .needsApproval: return 0
        case .waiting: return 1
        case .pendingWaiting: return 2
        case .working: return 3
        case .unknown: return 4
        case .abandoned: return 5
        }
    }

    public var displayLabel: String {
        switch self {
        case .working: return "Working"
        case .pendingWaiting: return "Working"  // Show as working until debounce completes
        case .needsApproval: return "Approval"
        case .waiting: return "Your turn"
        case .unknown: return "Unknown"
        case .abandoned: return "Idle"
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

// MARK: - Context Snapshot

/// A timestamped context usage snapshot for sparkline rendering.
public struct ContextSnapshot: Codable, Equatable {
    public let t: Date
    public let pct: Double
}

// MARK: - PR Status

/// Pull request status for a session's branch, fetched via `gh` CLI.
public enum PRStatus: String, Codable, Equatable {
    case none
    case open
    case merged
    case closed
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
    public var contextPct: Double?
    public var startedAt: Date?
    public var updatedAt: Date?

    /// Active subagents spawned by this session
    public var subagents: [Subagent]?

    /// PID of the Claude Code process (for liveness checking)
    public var pid: Int?

    /// Whether this session was discovered via hooks (full data) or fallback (limited data)
    public var isHookTracked: Bool

    /// If non-nil, this session lives on a remote machine (SSH host identifier)
    public var remoteHost: String?

    /// GitHub repo slug (e.g. "user/repo") if the cwd has a GitHub remote, nil otherwise
    public var githubRepo: String?

    /// iTerm2 session UUID, written back by the iTerm2 integration script
    public var iterm2SessionId: String?

    /// AI-generated session title (available after title generation completes)
    public var title: String?

    /// The first user prompt, used as a fallback label
    public var firstPrompt: String?

    /// Lines added relative to default branch (from git diff --shortstat)
    public var additions: Int?

    /// Lines deleted relative to default branch (from git diff --shortstat)
    public var deletions: Int?

    /// Timestamped context usage snapshots for sparkline display (last ~100 entries)
    public var contextSnapshots: [ContextSnapshot]?

    /// Timestamps when approval was requested (for sparkline markers)
    public var approvalTimestamps: [Date]?

    /// PR status for this session's branch (fetched Swift-side via `gh` CLI, not persisted)
    public var prStatus: PRStatus?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case projectName = "project_name"
        case status
        case model
        case gitBranch = "git_branch"
        case slug
        case contextPct = "context_pct"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
        case subagents
        case pid
        case isHookTracked = "is_hook_tracked"
        case remoteHost = "remote_host"
        case githubRepo = "github_repo"
        case iterm2SessionId = "iterm2_session_id"
        case title
        case firstPrompt = "first_prompt"
        case additions
        case deletions
        case contextSnapshots = "context_snapshots"
        case approvalTimestamps = "approval_timestamps"
        case prStatus = "pr_status"
    }

    public init(
        sessionId: String,
        cwd: String,
        projectName: String,
        status: AgentStatus = .unknown,
        model: String? = nil,
        gitBranch: String? = nil,
        slug: String? = nil,
        contextPct: Double? = nil,
        startedAt: Date? = nil,
        updatedAt: Date? = nil,
        subagents: [Subagent]? = nil,
        pid: Int? = nil,
        isHookTracked: Bool = false,
        remoteHost: String? = nil,
        githubRepo: String? = nil,
        iterm2SessionId: String? = nil,
        title: String? = nil,
        firstPrompt: String? = nil,
        additions: Int? = nil,
        deletions: Int? = nil,
        contextSnapshots: [ContextSnapshot]? = nil,
        approvalTimestamps: [Date]? = nil,
        prStatus: PRStatus? = nil
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.projectName = projectName
        self.status = status
        self.model = model
        self.gitBranch = gitBranch
        self.slug = slug
        self.contextPct = contextPct
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.subagents = subagents
        self.pid = pid
        self.isHookTracked = isHookTracked
        self.remoteHost = remoteHost
        self.githubRepo = githubRepo
        self.iterm2SessionId = iterm2SessionId
        self.title = title
        self.firstPrompt = firstPrompt
        self.additions = additions
        self.deletions = deletions
        self.contextSnapshots = contextSnapshots
        self.approvalTimestamps = approvalTimestamps
        self.prStatus = prStatus
    }

    /// Display title: AI-generated slug title, or a placeholder while generating
    public var displayTitle: String {
        if let title = title {
            return title
        }
        // Stable random placeholder seeded from session ID
        let placeholders = [
            "new-session",
            "getting-started",
            "loading...",
            "spinning-up",
            "warming-up",
            "initializing",
            "booting-up",
            "revving-up",
        ]
        let index = abs(sessionId.hashValue) % placeholders.count
        return placeholders[index]
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

    /// Formatted diff stats like "+120 −47", or nil if no data
    public var formattedDiffStats: String? {
        guard additions != nil || deletions != nil else { return nil }
        let add = additions ?? 0
        let del = deletions ?? 0
        if add == 0 && del == 0 { return nil }
        var parts: [String] = []
        if add > 0 { parts.append("+\(add)") }
        if del > 0 { parts.append("−\(del)") }
        return parts.joined(separator: " ")
    }

    /// GitHub compare URL for this branch — opens the existing PR if one exists,
    /// or the "Open a pull request" page if not.
    public var compareUrl: String? {
        guard let repo = githubRepo, let branch = gitBranch else { return nil }
        let encoded =
            branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? branch
        return "https://github.com/\(repo)/compare/\(encoded)?expand=1"
    }

    /// Human-readable idle duration since a given date
    public func idleSince(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        let minutes = Int(interval) / 60
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

// MARK: - Usage Limits (Claude API)

/// Raw API response from /api/oauth/usage.
struct UsageLimitsResponse: Codable {
    let fiveHour: LimitWindowResponse
    let sevenDay: LimitWindowResponse

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

struct LimitWindowResponse: Codable {
    let utilization: Double
    let resetsAt: String

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

/// Processed usage limits with calculated metrics for both windows.
public struct UsageLimitsData: Equatable {
    public let fiveHour: UsageLimitWindow
    public let sevenDay: UsageLimitWindow
    public let updatedAt: Date
}

/// A single usage limit window (5-hour or 7-day) with all display metrics.
public struct UsageLimitWindow: Equatable {
    /// Current utilization percentage from the API (0–100+).
    public let utilization: Double
    /// Average usage: what % of the window has elapsed (ideal constant rate).
    public let average: Double
    /// Estimated usage at end of window if current trend continues.
    public let estimated: Double
    /// When this window resets.
    public let resetsAt: Date
    /// Seconds until reset.
    public let remainingSeconds: TimeInterval

    /// Formatted remaining time like "2h 15m" or "1d 3h".
    public var remainingText: String {
        let total = Int(max(remainingSeconds, 0))
        let days = total / 86400
        let hours = (total % 86400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
