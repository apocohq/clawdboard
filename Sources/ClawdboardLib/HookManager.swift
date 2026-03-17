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
        "SessionStart", "PreToolUse", "PostToolUse", "PermissionRequest", "Stop",
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

        let hookScriptContent = try Self.scriptSource("clawdboard-hook.py")
        let destPath = hooksDir.appendingPathComponent("clawdboard-hook.py")
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
        let hookCommand = "python3 \(hooksDir.path)/clawdboard-hook.py"

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

    /// Remove Clawdboard hooks from settings.json and clean up local files.
    public func uninstall() throws {
        let fm = FileManager.default

        // Remove hooks from Claude settings
        if fm.fileExists(atPath: claudeSettingsPath.path) {
            let data = try Data(contentsOf: claudeSettingsPath)
            if var settings = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                var hooks = settings["hooks"] as? [String: Any]
            {
                for (event, eventHooks) in hooks {
                    guard var entries = eventHooks as? [[String: Any]] else { continue }
                    entries.removeAll { entry in
                        guard let hooksList = entry["hooks"] as? [[String: Any]] else {
                            return false
                        }
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
        }

        // Clean up ~/.clawdboard/sessions/ and hooks/
        try? fm.removeItem(at: sessionsDir)
        try? fm.removeItem(at: hooksDir)
    }

    /// The hook script content for remote installation
    public static func remoteHookScript() -> String {
        try! scriptSource("clawdboard-hook.py")
    }

    /// Load a Python script by name.
    /// Checks SPM bundle resources first, then falls back to repo-relative paths.
    public static func scriptSource(_ filename: String) throws -> String {
        // 1. SPM bundle resource (works in all build/install configurations)
        if let url = Bundle.module.url(
            forResource: (filename as NSString).deletingPathExtension,
            withExtension: (filename as NSString).pathExtension
        ) {
            if let content = try? String(contentsOf: url, encoding: .utf8) {
                return content
            }
        }

        // 2. Repo layout fallback
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        let repoPath =
            executableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ClawdboardLib/Resources/\(filename)")

        if let content = try? String(contentsOf: repoPath, encoding: .utf8) {
            return content
        }

        // 3. CWD fallback
        let cwdPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Sources/ClawdboardLib/Resources/\(filename)")
        if let content = try? String(contentsOf: cwdPath, encoding: .utf8) {
            return content
        }

        throw HookError.scriptNotFound(filename)
    }

    public enum HookError: Error, LocalizedError {
        case scriptNotFound(String)

        public var errorDescription: String? {
            switch self {
            case .scriptNotFound(let name):
                return "Hook script '\(name)' not found in bundle or Resources/"
            }
        }
    }
}
