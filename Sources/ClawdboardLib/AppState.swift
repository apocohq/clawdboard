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
    private var diffStatsProvider: DiffStatsProvider?
    private var prStatusProvider: PRStatusProvider?
    private var terminalTabPoller: TerminalTabPoller?

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
        startDiffStatsProvider()
        startPRStatusProvider()
        terminalTabPoller = TerminalTabPoller { [weak self] sessionId, newTitle in
            self?.handleTerminalTabRenamed(sessionId: sessionId, newTitle: newTitle)
        }

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
        diffStatsProvider = nil
        prStatusProvider = nil
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

    // MARK: - Diff Stats Provider

    private func startDiffStatsProvider() {
        guard diffStatsProvider == nil else { return }
        diffStatsProvider = DiffStatsProvider { [weak self] in
            self?.mergeDiffStats()
        }
    }

    /// Merge cached diff stats from the poller into session objects.
    /// Mutates the @Observable array directly — SwiftUI picks up the changes.
    private func mergeDiffStats() {
        guard let provider = diffStatsProvider else { return }
        for i in sessions.indices {
            if let stats = provider.diffStatsCache[sessions[i].sessionId] {
                if sessions[i].additions != stats.additions
                    || sessions[i].deletions != stats.deletions
                {
                    sessions[i].additions = stats.additions
                    sessions[i].deletions = stats.deletions
                }
            }
        }
    }

    /// Feed current sessions to the diff stats provider.
    private func refreshDiffStatsProviderTargets() {
        let targets = sessions.compactMap { session -> DiffStatsProvider.DiffStatsTarget? in
            guard !session.cwd.isEmpty,
                session.remoteHost == nil,
                session.displayStatus != .abandoned
            else { return nil }
            return DiffStatsProvider.DiffStatsTarget(sessionId: session.sessionId, cwd: session.cwd)
        }
        diffStatsProvider?.updateTargets(targets)
    }

    // MARK: - PR Status Provider

    private func startPRStatusProvider() {
        guard prStatusProvider == nil else { return }
        prStatusProvider = PRStatusProvider { [weak self] in
            self?.mergePRStatus()
        }
    }

    private func mergePRStatus() {
        guard let provider = prStatusProvider else { return }
        for i in sessions.indices {
            if let info = provider.prInfoCache[sessions[i].sessionId] {
                if sessions[i].prInfo != info {
                    sessions[i].prInfo = info
                }
            }
        }
    }

    private func refreshPRStatusProviderTargets() {
        let targets = sessions.compactMap { session -> PRStatusProvider.PRStatusTarget? in
            // Unlike diff stats, PR status is useful even for idle sessions
            guard session.remoteHost == nil,
                let repo = session.githubRepo,
                let branch = session.gitBranch
            else { return nil }
            return PRStatusProvider.PRStatusTarget(
                sessionId: session.sessionId, githubRepo: repo, gitBranch: branch)
        }
        prStatusProvider?.updateTargets(targets)
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

        let processedRemote = remoteSessions.values.flatMap { $0 }.compactMap { session -> AgentSession? in
            processSession(session, now: now)
        }

        var all = processedLocal + processedRemote

        autoDeleteStaleSessions(&all, now: now)

        let shouldPlayAlert = updateApprovalTracking(all)

        // Preserve diff stats from previous cycle (poller cache is the source of truth,
        // but freshly-parsed sessions arrive with nil additions/deletions).
        if let provider = diffStatsProvider {
            let cache = provider.diffStatsCache
            for i in all.indices {
                if let stats = cache[all[i].sessionId] {
                    all[i].additions = stats.additions
                    all[i].deletions = stats.deletions
                }
            }
        }

        // Preserve PR info from previous cycle or disk cache.
        if let provider = prStatusProvider {
            let sessionCache = provider.prInfoCache
            for i in all.indices {
                if let info = sessionCache[all[i].sessionId] {
                    all[i].prInfo = info
                } else if let repo = all[i].githubRepo,
                    let branch = all[i].gitBranch,
                    let info = provider.cachedInfo(repo: repo, branch: branch)
                {
                    all[i].prInfo = info
                }
            }
        }

        sessions = all
        refreshDiffStatsProviderTargets()
        refreshPRStatusProviderTargets()
        terminalTabPoller?.pruneExcept(activeSessionIds: Set(all.map(\.id)))

        if shouldPlayAlert {
            AlertSoundManager.shared.play()
        }
    }

    /// Remove sessions older than the configured auto-delete threshold.
    private func autoDeleteStaleSessions(_ all: inout [AgentSession], now: Date) {
        let autoDeleteHours = UserDefaults.standard.double(forKey: "autoDeleteHours")
        guard autoDeleteHours > 0 else { return }
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

    /// Detect sessions that just transitioned to needsApproval, update tracking, and return whether to play alert.
    private func updateApprovalTracking(_ all: [AgentSession]) -> Bool {
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
        return shouldPlayAlert
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
        Self.runProcess("/usr/bin/python3", arguments: [focusScript.path, uuid])
    }

    public func focusIDESession(_ session: AgentSession) {
        guard let lock = ideLockInfo(for: session) else { return }

        // Use workspace folder from lock file, fall back to session cwd.
        let folderPath = lock.workspaceFolders.first ?? session.cwd
        guard !folderPath.isEmpty else { return }

        let family = Self.ideFamily(for: lock.ideName)
        let command = Self.cliCommand(for: lock.ideName)

        // For VS Code family, prefer .code-workspace file if present.
        let targetPath =
            family == .vscode
            ? (Self.findCodeWorkspace(in: folderPath) ?? folderPath)
            : folderPath

        // Capture for JetBrains terminal tab focus via AX
        let tabTitle = session.terminalTabTitle
        let ideName = lock.ideName
        let sessionId = session.id

        let cwd = session.cwd

        // Hide Clawdboard so it doesn't overlap the AX click targets.
        // VS Code handles hiding internally — only when clicking is actually needed.
        if family != .vscode {
            NSApp.hide(nil)
        }

        if let executablePath = Self.findIDEExecutable(command: command, family: family) {
            Self.runProcess(executablePath, arguments: [targetPath])
            if family == .vscode {
                focusVSCodeSession(sessionId: sessionId, cwd: cwd, ideName: ideName)
            } else if family == .jetbrains {
                if let tabTitle = tabTitle {
                    focusJetBrainsTerminalTab(sessionId: sessionId, ideName: ideName, tabTitle: tabTitle)
                } else {
                    Self.activateJetBrainsTerminal()
                }
            } else {
                Self.restoreFloatingWindow()
            }
            return
        }

        // JetBrains fallback: use macOS `open -a` with the IDE's display name.
        if family == .jetbrains {
            Self.runProcess("/usr/bin/open", arguments: ["-a", lock.ideName, targetPath]) { status in
                if status == 0 {
                    if let tabTitle = tabTitle {
                        self.focusJetBrainsTerminalTab(
                            sessionId: sessionId, ideName: ideName, tabTitle: tabTitle)
                    } else {
                        Self.activateJetBrainsTerminal()
                    }
                } else {
                    Self.restoreFloatingWindow()
                    DispatchQueue.main.async {
                        Self.showIDECLIAlert(command: command, family: .jetbrains)
                    }
                }
            }
            return
        }

        Self.restoreFloatingWindow()
        DispatchQueue.main.async {
            Self.showIDECLIAlert(command: command, family: family)
        }
    }

    // MARK: - Process Helpers

    /// Run an executable asynchronously with stdout/stderr silenced.
    @discardableResult
    private static func runProcess(
        _ executable: String,
        arguments: [String],
        completion: ((Int32) -> Void)? = nil
    ) -> Process {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        DispatchQueue.global(qos: .userInitiated).async {
            try? task.run()
            task.waitUntilExit()
            completion?(task.terminationStatus)
        }
        return task
    }

    /// Restore the detached floating window after a focus operation hid the app.
    /// No-op when the floating window is not active.
    private static func restoreFloatingWindow() {
        DispatchQueue.main.async {
            guard UserDefaults.standard.bool(forKey: "showFloatingWindow") else { return }
            NSApp.unhide(nil)
            // Re-assert floating level on the detached window (unhide resets it).
            for window in NSApp.windows
            where window.title == "Clawdboard" && window.isVisible {
                window.level = .floating
            }
        }
    }

    /// Send ⌥F12 to the frontmost JetBrains IDE to activate the Terminal tool window.
    private static func activateJetBrainsTerminal() {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            Self.sendOptionF12()
            Self.restoreFloatingWindow()
        }
    }

    /// Run an AppleScript snippet synchronously. Must be called from a background thread.
    private static func runAppleScript(_ script: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// Send ⌥F12 synchronously via AppleScript. Must be called from a background thread.
    private static func sendOptionF12() {
        runAppleScript(
            """
            tell application "System Events"
                key code 111 using {option down}
            end tell
            """)
    }

    /// Find a running IDE application by its display name.
    private static func findIDEApp(ideName: String) -> NSRunningApplication? {
        let lower = ideName.lowercased()
        return NSWorkspace.shared.runningApplications.first { app in
            guard app.activationPolicy == .regular else { return false }
            if let name = app.localizedName?.lowercased() {
                return name.contains(lower) || lower.contains(name)
            }
            return false
        }
    }

    /// Find and click the terminal tab matching the session's title.
    /// If the Terminal tool window is closed (tab not found), sends ⌥F12 to open it and retries.
    /// Tracks the found element for rename detection via `terminalTabPoller`.
    private func focusJetBrainsTerminalTab(sessionId: String, ideName: String, tabTitle: String) {
        // Strip the status emoji prefix (e.g. "🔵 general-chat" → "general-chat")
        // so the AX search matches regardless of which status dot is currently showing.
        let searchTitle: String
        if let spaceIndex = tabTitle.firstIndex(of: " ") {
            searchTitle = String(tabTitle[tabTitle.index(after: spaceIndex)...])
        } else {
            searchTitle = tabTitle
        }

        let poller = self.terminalTabPoller
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            defer { Self.restoreFloatingWindow() }
            guard let app = Self.findIDEApp(ideName: ideName) else {
                debugLog("[JB] Could not find running IDE for '\(ideName)'")
                return
            }
            let pid = app.processIdentifier
            app.activate()
            Thread.sleep(forTimeInterval: 0.1)

            debugLog("[JB] Searching AX tree for tab '\(searchTitle)' in pid=\(pid)")
            var result = AccessibilityHelper.findAndActivateElement(
                pid: pid,
                titleContaining: searchTitle,
                maxDepth: 15
            )

            if !result.success {
                debugLog("[JB] Tab not found, sending ⌥F12 to open Terminal tool window")
                Self.sendOptionF12()
                Thread.sleep(forTimeInterval: 0.2)
                result = AccessibilityHelper.findAndActivateElement(
                    pid: pid,
                    titleContaining: searchTitle,
                    maxDepth: 15
                )
            }

            if let element = result.element {
                poller?.track(sessionId: sessionId, element: element)
            }
        }
    }

    /// Handle a terminal tab rename detected by the poller.
    /// Updates the session state file so the new title is used for future AX searches.
    private func handleTerminalTabRenamed(sessionId: String, newTitle: String) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[index].terminalTabTitle = newTitle

        // Write the updated title + user_renamed_tab flag back to the session state file.
        let sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/sessions")
        let stateFile = sessionsDir.appendingPathComponent("\(sessionId).json")
        guard
            var json = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: stateFile)) as? [String: Any]
        else { return }

        json["terminal_tab_title"] = newTitle
        json["user_renamed_tab"] = true
        if let data = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted) {
            let tmp = stateFile.appendingPathExtension("tmp")
            try? data.write(to: tmp)
            try? FileManager.default.moveItem(at: tmp, to: stateFile)
        }
        debugLog("[JB] Tab renamed for session \(sessionId): \"\(newTitle)\"")
    }

    // MARK: - VS Code Session Focus

    /// Read the AI-generated title from a Claude Code JSONL transcript.
    /// The VSCode extension writes `{"type":"ai-title","aiTitle":"..."}` entries.
    /// We scan from the end since the entry appears after the first assistant response.
    private static func readAITitle(cwd: String, sessionId: String) -> String? {
        // Path: ~/.claude/projects/{cwd-with-slashes-as-dashes}/{sessionId}.jsonl
        let projectDir =
            "-"
            + cwd.dropFirst()
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        let jsonlPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(projectDir)/\(sessionId).jsonl")

        guard let data = try? Data(contentsOf: jsonlPath) else {
            debugLog("[VSCode] Could not read JSONL at \(jsonlPath.path)")
            return nil
        }

        // Scan backwards for the ai-title line (usually near the start, but scan from end for safety)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        let lines = content.components(separatedBy: "\n")
        for line in lines.reversed() {
            guard line.contains("\"ai-title\"") else { continue }
            guard let lineData = line.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                json["type"] as? String == "ai-title",
                let aiTitle = json["aiTitle"] as? String
            else { continue }
            debugLog("[VSCode] Found aiTitle: \"\(aiTitle)\"")
            return aiTitle
        }
        debugLog("[VSCode] No ai-title entry found in JSONL")
        return nil
    }

    /// Focus a specific session in the VS Code Claude Code sidebar via Accessibility API.
    ///
    /// Flow:
    /// 1. Read the VSCode-generated `aiTitle` from the JSONL transcript
    /// 2. Enable Electron accessibility on the VS Code process
    /// 3. If the session is already active in the frontmost window, return early (no hide)
    /// 4. Hide Clawdboard, click "Session history", then click the target session
    private func focusVSCodeSession(sessionId: String, cwd: String, ideName: String) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.3) {
            defer { Self.restoreFloatingWindow() }
            guard let aiTitle = Self.readAITitle(cwd: cwd, sessionId: sessionId) else {
                debugLog("[VSCode] No aiTitle — cannot focus session")
                return
            }

            guard let app = Self.findIDEApp(ideName: ideName) else {
                debugLog("[VSCode] Could not find running IDE for '\(ideName)'")
                return
            }
            let pid = app.processIdentifier

            // Enable Electron accessibility tree (idempotent)
            AccessibilityHelper.enableElectronAccessibility(pid: pid)

            // Check if the current session already matches (avoid opening the picker needlessly).
            // By this point the `code` CLI has brought the correct window to the front,
            // so the AX tree of the frontmost window is what we're checking.
            if AccessibilityHelper.findButtonByTitlePrefix(pid: pid, titlePrefix: aiTitle) != nil {
                debugLog("[VSCode] Session '\(aiTitle)' is already the active session")
                return
            }

            // Session needs switching — hide Clawdboard so it doesn't intercept clicks.
            DispatchQueue.main.sync { NSApp.hide(nil) }

            // Click "Session history" to open the session picker
            guard let historyBtn = AccessibilityHelper.findButton(pid: pid, description: "Session history")
            else {
                debugLog("[VSCode] 'Session history' button not found")
                return
            }

            debugLog("[VSCode] Clicking 'Session history' button")
            AccessibilityHelper.click(historyBtn)
            Thread.sleep(forTimeInterval: 0.1)

            // Find the session in the picker by aiTitle prefix
            guard
                let sessionBtn = AccessibilityHelper.findButtonByTitlePrefix(
                    pid: pid, titlePrefix: aiTitle)
            else {
                debugLog("[VSCode] Session '\(aiTitle)' not found in picker — pressing Escape")
                Self.sendEscape()
                return
            }

            debugLog("[VSCode] Clicking session '\(aiTitle)'")
            AccessibilityHelper.click(sessionBtn)
        }
    }

    /// Send Escape key via AppleScript. Must be called from a background thread.
    private static func sendEscape() {
        runAppleScript(
            """
            tell application "System Events"
                key code 53
            end tell
            """)
    }

    /// Search standard paths for a CLI executable, returning the first match.
    private static func findIDEExecutable(command: String, family: IDEFamily) -> String? {
        let fm = FileManager.default
        var candidates = [
            "/usr/local/bin/\(command)",
            "/opt/homebrew/bin/\(command)",
        ]
        if family == .jetbrains {
            let home = fm.homeDirectoryForCurrentUser.path
            candidates.insert(
                "\(home)/Library/Application Support/JetBrains/Toolbox/scripts/\(command)", at: 0)
        }
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    // MARK: - IDE Family

    private enum IDEFamily {
        case vscode, jetbrains, unknown
    }

    private struct IDEDefinition {
        let keyword: String
        let family: IDEFamily
        let command: String
    }

    /// Single source of truth for keyword → (family, CLI command).
    /// Order matters — "insiders" must precede "code".
    private static let ideDefinitions: [IDEDefinition] = [
        // VS Code family
        .init(keyword: "insiders", family: .vscode, command: "code-insiders"),
        .init(keyword: "cursor", family: .vscode, command: "cursor"),
        .init(keyword: "code", family: .vscode, command: "code"),
        // JetBrains family
        .init(keyword: "webstorm", family: .jetbrains, command: "webstorm"),
        .init(keyword: "pycharm", family: .jetbrains, command: "pycharm"),
        .init(keyword: "intellij", family: .jetbrains, command: "idea"),
        .init(keyword: "goland", family: .jetbrains, command: "goland"),
        .init(keyword: "rubymine", family: .jetbrains, command: "rubymine"),
        .init(keyword: "rider", family: .jetbrains, command: "rider"),
        .init(keyword: "clion", family: .jetbrains, command: "clion"),
        .init(keyword: "phpstorm", family: .jetbrains, command: "phpstorm"),
        .init(keyword: "datagrip", family: .jetbrains, command: "datagrip"),
        .init(keyword: "rustrover", family: .jetbrains, command: "rustrover"),
        .init(keyword: "aqua", family: .jetbrains, command: "aqua"),
    ]

    private static func ideFamily(for ideName: String) -> IDEFamily {
        let lower = ideName.lowercased()
        return ideDefinitions.first(where: { lower.contains($0.keyword) })?.family ?? .unknown
    }

    private static func cliCommand(for ideName: String) -> String {
        let lower = ideName.lowercased()
        return ideDefinitions.first(where: { lower.contains($0.keyword) })?.command ?? "code"
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

    private static func showIDECLIAlert(command: String, family: IDEFamily) {
        let alert = NSAlert()
        alert.messageText = "'\(command)' command not found"
        switch family {
        case .vscode:
            alert.informativeText =
                "Install it from VS Code: open the Command Palette (Cmd+Shift+P) "
                + "and run \"Shell Command: Install '\(command)' command in PATH\"."
        case .jetbrains:
            alert.informativeText =
                "Install it via JetBrains Toolbox (Settings > Tools > Shell Scripts) "
                + "or from the IDE: Tools > Create Command-line Launcher."
        case .unknown:
            alert.informativeText = "Could not find the '\(command)' CLI tool on your PATH."
        }
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
