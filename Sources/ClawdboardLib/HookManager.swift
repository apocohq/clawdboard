import Foundation

/// Manages installation and updates of Clawdboard hooks in ~/.claude/settings.json.
/// Hooks are the primary mechanism for session discovery and state tracking.
public class HookManager {
    public static let shared = HookManager()

    private let clawdboardDir: URL
    private let hooksDir: URL
    private let sessionsDir: URL
    private let claudeSettingsPath: URL

    public init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        clawdboardDir = home.appendingPathComponent(".clawdboard")
        hooksDir = clawdboardDir.appendingPathComponent("hooks")
        sessionsDir = clawdboardDir.appendingPathComponent("sessions")
        claudeSettingsPath = home.appendingPathComponent(".claude/settings.json")
    }

    /// Path to the sessions directory where hook state files are written
    public var sessionsDirectoryPath: String {
        sessionsDir.path
    }

    /// All hook events we register for. Claude Code requires each as a separate key.
    private static let hookEvents: [String] = [
        "SessionStart", "PostToolUse", "PermissionRequest", "Stop",
        "UserPromptSubmit", "SessionEnd", "SubagentStart", "SubagentStop",
    ]

    /// Check if all expected hooks are installed
    public var isInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettingsPath),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        return Self.hookEvents.allSatisfy { event in
            guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
            return eventHooks.contains { entry in
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { return false }
                return hooksList.contains { hook in
                    guard let command = hook["command"] as? String else { return false }
                    return command.contains("clawdboard")
                }
            }
        }
    }

    /// Create directories and install the hook script
    public func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: hooksDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: sessionsDir, withIntermediateDirectories: true)
    }

    /// Install the hook script from the app bundle to ~/.clawdboard/hooks/
    public func installHookScript() throws {
        let fm = FileManager.default
        try ensureDirectories()

        let hookScriptContent = Self.hookScriptSource()
        let destPath = hooksDir.appendingPathComponent("clawdboard-hook.sh")
        try hookScriptContent.write(to: destPath, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath.path)
    }

    /// Merge Clawdboard hooks into ~/.claude/settings.json, preserving existing hooks.
    public func installHooksInSettings() throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]

        if fm.fileExists(atPath: claudeSettingsPath.path) {
            let data = try Data(contentsOf: claudeSettingsPath)
            if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookCommand = "bash \(hooksDir.path)/clawdboard-hook.sh"

        let hookEntry: [String: Any] = [
            "type": "command",
            "command": hookCommand,
            "timeout": 10,
        ]

        let removeClawdboard: ([[String: Any]]) -> [[String: Any]] = { entries in
            entries.filter { entry in
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { return true }
                return !hooksList.contains { hook in
                    (hook["command"] as? String)?.contains("clawdboard") == true
                }
            }
        }

        // Register the same hook for all standard events
        for event in Self.hookEvents {
            var eventHooks = removeClawdboard(hooks[event] as? [[String: Any]] ?? [])
            eventHooks.append(["matcher": "*", "hooks": [hookEntry]])
            hooks[event] = eventHooks
        }

        // Notification hooks use specific matchers to distinguish type
        var notifHooks = removeClawdboard(hooks["Notification"] as? [[String: Any]] ?? [])
        for matcher in ["idle_prompt", "permission_prompt"] {
            let entry: [String: Any] = [
                "type": "command",
                "command": hookCommand + " \(matcher)",
                "timeout": 10,
            ]
            notifHooks.append(["matcher": matcher, "hooks": [entry]])
        }
        hooks["Notification"] = notifHooks

        settings["hooks"] = hooks

        let data = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: claudeSettingsPath, options: .atomic)
    }

    /// Full install: script + settings
    public func install() throws {
        try installHookScript()
        try installHooksInSettings()
    }

    /// Remove Clawdboard hooks from settings.json
    public func uninstall() throws {
        guard FileManager.default.fileExists(atPath: claudeSettingsPath.path) else { return }

        let data = try Data(contentsOf: claudeSettingsPath)
        guard var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            var hooks = settings["hooks"] as? [String: Any]
        else { return }

        for (event, eventHooks) in hooks {
            guard var entries = eventHooks as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { return false }
                return hooksList.contains { hook in
                    (hook["command"] as? String)?.contains("clawdboard") == true
                }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        settings["hooks"] = hooks.isEmpty ? nil : hooks

        let newData = try JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: claudeSettingsPath, options: .atomic)
    }

    /// The hook script content — read from repo or fallback to embedded
    private static func hookScriptSource() -> String {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let repoHookPath =
            executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("hooks/clawdboard-hook.sh")

        if let content = try? String(contentsOf: repoHookPath, encoding: .utf8) {
            return content
        }

        let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("hooks/clawdboard-hook.sh")
        if let content = try? String(contentsOf: cwdPath, encoding: .utf8) {
            return content
        }

        return embeddedHookScript
    }

    private static let embeddedHookScript = """
        #!/bin/bash
        set -euo pipefail
        SESSIONS_DIR="$HOME/.clawdboard/sessions"
        mkdir -p "$SESSIONS_DIR"
        INPUT=$(cat)
        SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('session_id',''))")
        HOOK_EVENT=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('hook_event_name',''))")
        CWD=$(echo "$INPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('cwd',''))")
        NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        [ -z "$SESSION_ID" ] && exit 0
        STATE_FILE="$SESSIONS_DIR/$SESSION_ID.json"
        PROJECT_NAME=$(basename "$CWD")
        case "$HOOK_EVENT" in
            SessionStart|PostToolUse|UserPromptSubmit)
                python3 -c "
        import json,os
        s = json.load(open('$STATE_FILE')) if os.path.isfile('$STATE_FILE') else {}
        s.update({'session_id':'$SESSION_ID','cwd':'$CWD','project_name':'$PROJECT_NAME','status':'working','updated_at':'$NOW','is_hook_tracked':True})
        s.setdefault('started_at','$NOW')
        json.dump(s,open('$STATE_FILE','w'),indent=2)
        ";;
            Stop)
                [ -f "$STATE_FILE" ] && python3 -c "
        import json
        s=json.load(open('$STATE_FILE'))
        s['status']='pending_waiting'
        s['updated_at']='$NOW'
        json.dump(s,open('$STATE_FILE','w'),indent=2)
        ";;
            PermissionRequest)
                [ -f "$STATE_FILE" ] && python3 -c "
        import json
        s=json.load(open('$STATE_FILE'))
        s['status']='needs_approval'
        s['updated_at']='$NOW'
        json.dump(s,open('$STATE_FILE','w'),indent=2)
        ";;
            SessionEnd)
                rm -f "$STATE_FILE";;
        esac
        echo '{"suppressOutput": true}'
        exit 0
        """
}
