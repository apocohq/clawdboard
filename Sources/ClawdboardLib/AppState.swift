import AppKit
import Foundation
import Observation

/// Central app state — reads session state files written by hooks
/// and provides computed properties for the UI.
@Observable
public class AppState {
    // MARK: - Session Data

    public var sessions: [AgentSession] = []

    // MARK: - Remote Hosts

    public var remoteHosts: [RemoteHost] = []

    // MARK: - Usage Limits (Claude API)

    public var usageLimits: UsageLimitsData?
    public var usageLimitsError: String?

    // MARK: - UI State

    public var expandedSessionId: String?
    public var collapsedGroups: Set<String> = []

    // MARK: - Dependencies

    private var stateWatcher: SessionStateWatcher?
    private var remoteWatcher: RemoteSessionWatcher?
    private var usageLimitsWatcher: UsageLimitsWatcher?

    /// Remote sessions keyed by host identifier
    private var remoteSessions: [String: [AgentSession]] = [:]

    /// Local sessions from the local watcher
    private var localSessions: [AgentSession] = []

    /// Previous display statuses keyed by session ID — used to detect transitions to needsApproval
    private var previousStatuses: [String: AgentStatus] = [:]

    private static let remoteHostsKey = "remoteHosts"

    private let sessionsDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/sessions")
    }()

    private let ideLockDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/ide")
    }()

    /// All parsed IDE lock files.
    private var ideLocks: [IdeLockInfo] = []

    public init() {
        loadRemoteHosts()
    }

    // MARK: - Lifecycle

    public func start() {
        stateWatcher = SessionStateWatcher { [weak self] hookSessions in
            self?.localSessions = hookSessions
            self?.rebuildSessions()
        }
        stateWatcher?.start()

        startRemoteWatcher()
        startUsageLimitsWatcher()
    }

    public func stop() {
        stateWatcher?.stop()
        stateWatcher = nil
        remoteWatcher?.stop()
        remoteWatcher = nil
        usageLimitsWatcher?.stop()
        usageLimitsWatcher = nil
    }

    // MARK: - Remote Host Management

    public func addRemoteHost(host: String = "", label: String = "") {
        let entry = RemoteHost(host: host, label: label)
        remoteHosts.append(entry)
        saveRemoteHosts()
        if !host.isEmpty {
            remoteWatcher?.updateHosts(remoteHosts)
        }
    }

    public func updateRemoteHost(at index: Int, with host: RemoteHost) {
        guard remoteHosts.indices.contains(index) else { return }
        let oldId = remoteHosts[index].host
        remoteHosts[index] = host

        if oldId != host.host {
            remoteSessions.removeValue(forKey: oldId)
        }

        saveRemoteHosts()
        remoteWatcher?.updateHosts(remoteHosts)
        rebuildSessions()
    }

    public func removeRemoteHost(at index: Int) {
        guard remoteHosts.indices.contains(index) else { return }
        let hostId = remoteHosts[index].host
        remoteHosts.remove(at: index)
        remoteSessions.removeValue(forKey: hostId)
        saveRemoteHosts()
        remoteWatcher?.updateHosts(remoteHosts)
        rebuildSessions()
    }

    // MARK: - Session Deletion

    /// Delete a session's state file, removing it from the UI.
    public func deleteSession(_ sessionId: String) {
        let remoteHost = sessions.first(where: { $0.sessionId == sessionId })?.remoteHost

        if let host = remoteHost {
            remoteSessions[host]?.removeAll { $0.sessionId == sessionId }
            rebuildSessions()
            remoteWatcher?.deleteSession(sessionId, on: host)
        } else {
            let file = sessionsDir.appendingPathComponent("\(sessionId).json")
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Persistence

    private func saveRemoteHosts() {
        if let data = try? JSONEncoder().encode(remoteHosts) {
            UserDefaults.standard.set(data, forKey: Self.remoteHostsKey)
        }
    }

    private func loadRemoteHosts() {
        guard let data = UserDefaults.standard.data(forKey: Self.remoteHostsKey),
            let hosts = try? JSONDecoder().decode([RemoteHost].self, from: data)
        else { return }
        remoteHosts = hosts
    }

    // MARK: - Remote Watcher

    private func startRemoteWatcher() {
        remoteWatcher = RemoteSessionWatcher { [weak self] host, sessions in
            self?.remoteSessions[host] = sessions
            self?.rebuildSessions()
        }
        remoteWatcher?.updateHosts(remoteHosts)
    }

    // MARK: - Usage Limits Watcher

    private func startUsageLimitsWatcher() {
        guard usageLimitsWatcher == nil else { return }
        usageLimitsWatcher = UsageLimitsWatcher(
            onChange: { [weak self] data in
                self?.usageLimits = data
            },
            onError: { [weak self] error in
                self?.usageLimitsError = error
            }
        )
        usageLimitsWatcher?.start()
    }

    /// Manually refresh usage limits.
    public func refreshUsageLimits() {
        usageLimitsWatcher?.refresh()
    }

    // MARK: - IDE Lock Files

    /// Scan ~/.claude/ide/*.lock for IDE window info.
    private func refreshIdeLocks() {
        var locks: [IdeLockInfo] = []
        let fm = FileManager.default
        guard
            let contents = try? fm.contentsOfDirectory(
                at: ideLockDir, includingPropertiesForKeys: nil)
        else {
            ideLocks = locks
            return
        }
        let decoder = JSONDecoder()
        for url in contents where url.pathExtension == "lock" {
            guard let data = try? Data(contentsOf: url),
                let info = try? decoder.decode(IdeLockInfo.self, from: data)
            else { continue }
            locks.append(info)
        }
        ideLocks = locks
    }

    /// Match a session to an IDE window by checking if its cwd falls within
    /// one of the lock file's workspace folders. Picks the most specific
    /// (longest) match so worktrees are distinguished from their parent repo.
    public func ideLockInfo(for session: AgentSession) -> IdeLockInfo? {
        let cwd = session.cwd
        guard !cwd.isEmpty else { return nil }

        var bestMatch: IdeLockInfo?
        var bestLength = 0

        for lock in ideLocks {
            for folder in lock.workspaceFolders {
                guard cwd.hasPrefix(folder), folder.count > bestLength else { continue }
                bestMatch = lock
                bestLength = folder.count
            }
        }
        return bestMatch
    }

    // MARK: - Session Merging

    private func rebuildSessions() {
        refreshIdeLocks()
        let now = Date()

        let processedLocal = localSessions.compactMap { session -> AgentSession? in
            processSession(session, now: now)
        }

        let processedRemote = remoteSessions.values.flatMap { $0 }.compactMap {
            session -> AgentSession? in
            processSession(session, now: now)
        }

        var all = processedLocal + processedRemote

        // Auto-delete stale sessions if configured (0 = never)
        let autoDeleteHours = UserDefaults.standard.double(forKey: "autoDeleteHours")
        if autoDeleteHours > 0 {
            all.removeAll { session in
                guard let updated = session.updatedAt ?? session.startedAt else { return false }
                let age = now.timeIntervalSince(updated) / 3600.0
                if age >= autoDeleteHours {
                    deleteSession(session.sessionId)
                    return true
                }
                return false
            }
        }

        // Detect any session that just transitioned to needsApproval
        var shouldPlayAlert = false
        for session in all {
            let display = session.displayStatus
            let previous = previousStatuses[session.sessionId]
            if display == .needsApproval && previous != nil && previous != .needsApproval {
                shouldPlayAlert = true
            }
            previousStatuses[session.sessionId] = display
        }
        // Clean up stale entries
        let activeIds = Set(all.map(\.sessionId))
        previousStatuses = previousStatuses.filter { activeIds.contains($0.key) }

        sessions = all

        if shouldPlayAlert {
            AlertSoundManager.shared.play()
        }
    }

    // MARK: - Session Processing

    /// Apply ghost filtering, debounce, staleness, and abandoned logic to a session.
    private func processSession(_ session: AgentSession, now: Date) -> AgentSession? {
        var s = session

        // Ghost session filter: no model means the session never produced output
        if s.model == nil {
            if let started = s.startedAt, let updated = s.updatedAt {
                let neverUpdated = abs(updated.timeIntervalSince(started)) < 1.0
                if neverUpdated, now.timeIntervalSince(started) > 30 {
                    return nil
                }
                if now.timeIntervalSince(updated) > 300 {
                    return nil
                }
            }
            guard let started = s.startedAt, now.timeIntervalSince(started) < 60 else {
                return nil
            }
        }

        if let updatedAt = s.updatedAt {
            let age = now.timeIntervalSince(updatedAt)
            if s.status == .pendingWaiting, age >= 1.5 {
                s.status = .waiting
            }
            if s.status == .working, age >= 15.0 {
                s.status = .waiting
            }
            if s.status == .waiting, age >= 600.0 {
                s.status = .abandoned
            }
        }
        return s
    }

    // MARK: - Computed Properties

    /// Sessions sorted by start time, newest first (stable order).
    public var sortedSessions: [AgentSession] {
        sessions.sorted { a, b in
            (a.startedAt ?? .distantPast) > (b.startedAt ?? .distantPast)
        }
    }

    /// Sessions that are actively doing something (working or waiting for input)
    public var activeSessions: [AgentSession] {
        sortedSessions.filter {
            $0.displayStatus != .unknown && $0.displayStatus != .abandoned
        }
    }

    public var needsApprovalCount: Int {
        sessions.count { $0.displayStatus == .needsApproval }
    }

    public var waitingCount: Int {
        sessions.count { $0.displayStatus == .waiting }
    }

    public var workingCount: Int {
        sessions.count { $0.displayStatus == .working }
    }

    // MARK: - Actions

    public func toggleExpanded(sessionId: String) {
        if expandedSessionId == sessionId {
            expandedSessionId = nil
        } else {
            expandedSessionId = sessionId
        }
    }

    public func toggleGroupCollapsed(_ groupKey: String) {
        if collapsedGroups.contains(groupKey) {
            collapsedGroups.remove(groupKey)
        } else {
            collapsedGroups.insert(groupKey)
        }
    }

    public func focusITerm2Session(_ session: AgentSession) {
        guard let uuid = session.iterm2SessionId else { return }
        let focusScript = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/iterm2-focus.py")
        guard FileManager.default.fileExists(atPath: focusScript.path) else { return }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = [focusScript.path, uuid]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
            task.waitUntilExit()
        }
    }

    public func focusVSCodeSession(_ session: AgentSession) {
        guard let lock = ideLockInfo(for: session) else { return }

        // Use workspace folder from lock file, fall back to session cwd.
        let folderPath = lock.workspaceFolders.first ?? session.cwd
        guard !folderPath.isEmpty else { return }

        // If the folder contains a .code-workspace file, pass that instead so
        // the `code` CLI focuses the existing workspace window rather than
        // opening the folder as a new window.
        let targetPath = Self.findCodeWorkspace(in: folderPath) ?? folderPath

        // Derive CLI command from IDE name.
        let command = Self.cliCommand(for: lock.ideName)

        let fm = FileManager.default
        let candidates = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
        ]

        guard let executablePath = candidates.first(where: { fm.isExecutableFile(atPath: $0) })
        else {
            DispatchQueue.main.async {
                Self.showVSCodeCLIAlert(command: command)
            }
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: executablePath)
        task.arguments = [targetPath]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
            task.waitUntilExit()
        }
    }

    /// Map IDE name from the lock file to the corresponding CLI command.
    private static func cliCommand(for ideName: String) -> String {
        let lower = ideName.lowercased()
        if lower.contains("insiders") { return "code-insiders" }
        if lower.contains("cursor") { return "cursor" }
        return "code"
    }

    /// Look for a single `.code-workspace` file in the given directory.
    private static func findCodeWorkspace(in folderPath: String) -> String? {
        let url = URL(fileURLWithPath: folderPath)
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return nil }
        let workspaceFiles = contents.filter { $0.pathExtension == "code-workspace" }
        // Only use it if there's exactly one — ambiguous otherwise.
        return workspaceFiles.count == 1 ? workspaceFiles[0].path : nil
    }

    private static func showVSCodeCLIAlert(command: String) {
        let alert = NSAlert()
        alert.messageText = "'\(command)' command not found"
        alert.informativeText =
            "Install it from VS Code: open the Command Palette (Cmd+Shift+P) "
            + "and run \"Shell Command: Install '\(command)' command in PATH\"."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Display Status Helper

extension AgentSession {
    /// The status to show in the UI, accounting for debounce
    /// (pending_waiting shows as "working" until debounced to "waiting")
    public var displayStatus: AgentStatus {
        switch status {
        case .pendingWaiting: return .working
        default: return status
        }
    }
}
