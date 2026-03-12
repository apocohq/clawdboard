import Foundation
import Testing

@testable import ClawdboardLib

@Suite("HookManager")
struct HookManagerTests {

    @Test("isInstalled returns true when hooks exist in settings")
    func isInstalledDetectsHooks() {
        // This tests against the real ~/.claude/settings.json
        // which should have hooks installed from our earlier setup
        let manager = HookManager.shared
        #expect(manager.isInstalled == true)
    }

    @Test("sessionsDirectoryPath points to ~/.clawdboard/sessions")
    func sessionsDirectory() {
        let manager = HookManager()
        let expected = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".clawdboard/sessions").path
        #expect(manager.sessionsDirectoryPath == expected)
    }
}
