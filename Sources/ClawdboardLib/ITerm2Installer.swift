import Foundation

/// Manages installation of iTerm2 integration scripts.
public enum ITerm2Installer {
    private static let autoLaunchDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/iterm2/AppSupport/Scripts/AutoLaunch")
    }()

    private static let focusScriptDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard")
    }()

    private static var autoLaunchDest: URL {
        autoLaunchDir.appendingPathComponent("clawdboard.py")
    }

    private static var focusScriptDest: URL {
        focusScriptDir.appendingPathComponent("iterm2-focus.py")
    }

    /// Whether iTerm2.app is present on this machine.
    public static var isITerm2Available: Bool {
        FileManager.default.fileExists(atPath: "/Applications/iTerm.app")
    }

    /// Whether iTerm2's Python API is enabled (required for the integration script).
    public static var isPythonAPIEnabled: Bool {
        UserDefaults(suiteName: "com.googlecode.iterm2")?
            .bool(forKey: "EnableAPIServer") == true
    }

    /// Whether both iTerm2 scripts are installed at their expected locations.
    public static var isInstalled: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: autoLaunchDest.path)
            && fm.fileExists(atPath: focusScriptDest.path)
    }

    /// Install both iTerm2 integration scripts.
    public static func install() throws {
        let fm = FileManager.default

        // Load script sources
        let integrationSource = try HookManager.scriptSource("iterm2-integration.py")
        let focusSource = try HookManager.scriptSource("iterm2-focus.py")

        // Create directories
        try fm.createDirectory(at: autoLaunchDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: focusScriptDir, withIntermediateDirectories: true)

        // Write integration script
        try integrationSource.write(to: autoLaunchDest, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: autoLaunchDest.path)

        // Write focus script
        try focusSource.write(to: focusScriptDest, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: focusScriptDest.path)
    }

    /// Remove both iTerm2 integration scripts and stop the running instance.
    public static func uninstall() {
        let fm = FileManager.default
        try? fm.removeItem(at: autoLaunchDest)
        try? fm.removeItem(at: focusScriptDest)
        // Kill any running instances
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        task.arguments = ["-f", "clawdboard.py"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }

    /// Ask iTerm2 to launch the AutoLaunch script via AppleScript (avoids manual restart).
    public static func launchScript() {
        let script = """
            tell application "iTerm2"
                launch API script named "clawdboard.py"
            end tell
            """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
