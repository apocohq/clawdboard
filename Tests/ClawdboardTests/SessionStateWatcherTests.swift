import Foundation
import Testing

@testable import ClawdboardLib

@Suite("SessionStateWatcher")
struct SessionStateWatcherTests {

    @Test("readAllSessions parses JSON state files")
    func readsStateFiles() throws {
        // Create a temp directory with test state files
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Use current PID so the session passes the "process alive" check
        let stateJSON = """
            {
                "session_id": "test-123",
                "cwd": "/tmp/test",
                "project_name": "test",
                "status": "working",
                "model": "claude-opus-4-6",
                "context_pct": 42.0,
                "started_at": "2026-03-12T08:00:00Z",
                "updated_at": "2026-03-12T09:00:00Z",
                "is_hook_tracked": true,
                "pid": \(ProcessInfo.processInfo.processIdentifier)
            }
            """
        try stateJSON.write(
            to: tmpDir.appendingPathComponent("test-123.json"),
            atomically: true, encoding: .utf8
        )

        let watcher = SessionStateWatcher(sessionsDirectory: tmpDir.path) { _ in }
        let sessions = watcher.readAllSessions()

        #expect(sessions.count == 1)
        #expect(sessions[0].sessionId == "test-123")
        #expect(sessions[0].status == .working)
        #expect(sessions[0].model == "claude-opus-4-6")
        #expect(sessions[0].contextPct == 42.0)
    }

    @Test("readAllSessions skips non-json files")
    func skipsNonJSON() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "not json".write(
            to: tmpDir.appendingPathComponent("readme.txt"),
            atomically: true, encoding: .utf8
        )
        try "{}invalid".write(
            to: tmpDir.appendingPathComponent("bad.json"),
            atomically: true, encoding: .utf8
        )

        let watcher = SessionStateWatcher(sessionsDirectory: tmpDir.path) { _ in }
        let sessions = watcher.readAllSessions()
        #expect(sessions.isEmpty)
    }

    @Test("readAllSessions handles empty directory")
    func handlesEmptyDir() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawdboard-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let watcher = SessionStateWatcher(sessionsDirectory: tmpDir.path) { _ in }
        let sessions = watcher.readAllSessions()
        #expect(sessions.isEmpty)
    }
}
