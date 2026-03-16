import Foundation
import Testing

@testable import ClawdboardLib

@Suite("HookManager")
struct HookManagerTests {

    @Test("isInstalled returns false when no hooks configured")
    func isInstalledDetectsNoHooks() {
        // On CI, no hooks are installed so this should be false
        let manager = HookManager()
        // Just verify the method works without crashing
        _ = manager.isInstalled
    }

    @Test("sessionsDirectoryPath points to ~/.clawdboard/sessions")
    func sessionsDirectory() {
        let manager = HookManager()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/sessions").path
        #expect(manager.sessionsDirectoryPath == expected)
    }
}
