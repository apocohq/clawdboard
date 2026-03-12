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

    /// The set of hook events we expect to be registered
    private static let expectedEvents: Set<String> = [
        "SessionStart", "PostToolUse", "PermissionRequest", "Stop",
        "UserPromptSubmit", "SessionEnd", "SubagentStart", "SubagentStop",
        "Notification",
    ]

    /// Check if all expected hooks are installed
    public var isInstalled: Bool {
        guard let data = try? Data(contentsOf: claudeSettingsPath),
            let settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = settings["hooks"] as? [String: Any]
        else { return false }

        // Check that every expected event has a clawdboard hook
        return Self.expectedEvents.allSatisfy { event in
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

        // Find the hook script — it's bundled with the app or in known locations
        let hookScriptContent = Self.hookScriptSource()
        let destPath = hooksDir.appendingPathComponent("clawdboard-hook.sh")
        try hookScriptContent.write(to: destPath, atomically: true, encoding: .utf8)

        // Make executable
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destPath.path)
    }

    /// Merge Clawdboard hooks into ~/.claude/settings.json, preserving existing hooks.
    public func installHooksInSettings() throws {
        let fm = FileManager.default
        var settings: [String: Any] = [:]

        // Read existing settings
        if fm.fileExists(atPath: claudeSettingsPath.path) {
            let data = try Data(contentsOf: claudeSettingsPath)
            if let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }
        }

        // Get or create hooks dict
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        let hookCommand = "bash \(hooksDir.path)/clawdboard-hook.sh"

        // Define our hook entries for each event
        let clawdboardHookEntry: [String: Any] = [
            "type": "command",
            "command": hookCommand,
            "timeout": 10,
        ]

        // Events with their matchers
        let hookEvents: [(event: String, matcher: String)] = [
            ("SessionStart", "*"),
            ("PostToolUse", "*"),
            ("PermissionRequest", "*"),
            ("Stop", "*"),
            ("UserPromptSubmit", "*"),
            ("SessionEnd", "*"),
            ("SubagentStart", "*"),
            ("SubagentStop", "*"),
        ]

        // Notification has special matchers — separate command args to distinguish type
        let idleHookEntry: [String: Any] = [
            "type": "command",
            "command": hookCommand + " idle_prompt",
            "timeout": 10,
        ]
        let permissionHookEntry: [String: Any] = [
            "type": "command",
            "command": hookCommand + " permission_prompt",
            "timeout": 10,
        ]
        let idlePromptEntry: [String: Any] = [
            "matcher": "idle_prompt",
            "hooks": [idleHookEntry],
        ]
        let permissionPromptEntry: [String: Any] = [
            "matcher": "permission_prompt",
            "hooks": [permissionHookEntry],
        ]

        for (event, matcher) in hookEvents {
            var eventHooks = hooks[event] as? [[String: Any]] ?? []

            // Remove any existing clawdboard entries (for reinstall)
            eventHooks.removeAll { entry in
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { return false }
                return hooksList.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return cmd.contains("clawdboard")
                }
            }

            // Add our entry
            let newEntry: [String: Any] = [
                "matcher": matcher,
                "hooks": [clawdboardHookEntry],
            ]
            eventHooks.append(newEntry)
            hooks[event] = eventHooks
        }

        // Handle Notification separately (special matcher)
        var notificationHooks = hooks["Notification"] as? [[String: Any]] ?? []
        notificationHooks.removeAll { entry in
            guard let hooksList = entry["hooks"] as? [[String: Any]] else { return false }
            return hooksList.contains { hook in
                guard let cmd = hook["command"] as? String else { return false }
                return cmd.contains("clawdboard")
            }
        }
        notificationHooks.append(idlePromptEntry)
        notificationHooks.append(permissionPromptEntry)
        hooks["Notification"] = notificationHooks

        settings["hooks"] = hooks

        // Write back atomically
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
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

        // Remove clawdboard entries from all events
        for (event, eventHooks) in hooks {
            guard var entries = eventHooks as? [[String: Any]] else { continue }
            entries.removeAll { entry in
                guard let hooksList = entry["hooks"] as? [[String: Any]] else { return false }
                return hooksList.contains { hook in
                    guard let cmd = hook["command"] as? String else { return false }
                    return cmd.contains("clawdboard")
                }
            }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        let newData = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        try newData.write(to: claudeSettingsPath, options: .atomic)
    }

    /// The hook script content — embedded so we don't need bundle resource management
    private static func hookScriptSource() -> String {
        // Read from the hooks directory relative to the executable
        // In development: the repo's hooks/ directory
        // In production: bundled with the app
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

        // Fallback: try relative to current working directory
        let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("hooks/clawdboard-hook.sh")
        if let content = try? String(contentsOf: cwdPath, encoding: .utf8) {
            return content
        }

        // Last resort: embedded minimal version
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
                STATUS="working"
                [ "$HOOK_EVENT" = "PostToolUse" ] && [ -f "$STATE_FILE" ] && STATUS=$(python3 -c "import json; print(json.load(open('$STATE_FILE')).get('status','working'))")
                [ "$HOOK_EVENT" = "PostToolUse" ] && STATUS="working"
                python3 -c "
        import json,os
        s = json.load(open('$STATE_FILE')) if os.path.isfile('$STATE_FILE') else {}
        s.update({'session_id':'$SESSION_ID','cwd':'$CWD','project_name':'$PROJECT_NAME','status':'$STATUS','updated_at':'$NOW','is_hook_tracked':True})
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
            Notification)
                [ -f "$STATE_FILE" ] && python3 -c "
        import json
        s=json.load(open('$STATE_FILE'))
        s['status']='waiting'
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
