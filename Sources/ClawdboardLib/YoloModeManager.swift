import Foundation

/// Manages "YOLO mode" — auto-approve all permission requests.
/// When enabled, the hook script will return {"decision": "allow"} for all PermissionRequest events.
public class YoloModeManager {
    public static let shared = YoloModeManager()

    private let yoloModeFile: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/yolo-mode")
    }()

    private init() {}

    /// Whether YOLO mode is currently enabled.
    public var isEnabled: Bool {
        get { FileManager.default.fileExists(atPath: yoloModeFile.path) }
        set {
            if newValue {
                enable()
            } else {
                disable()
            }
        }
    }

    /// Enable YOLO mode by creating the marker file.
    private func enable() {
        let dir = yoloModeFile.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: yoloModeFile.path, contents: nil)
    }

    /// Disable YOLO mode by removing the marker file.
    private func disable() {
        try? FileManager.default.removeItem(at: yoloModeFile)
    }
}
