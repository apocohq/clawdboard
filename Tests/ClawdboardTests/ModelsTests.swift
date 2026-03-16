import Foundation
import Testing

@testable import ClawdboardLib

@Suite("Models")
struct ModelsTests {

    // MARK: - AgentStatus

    @Test("AgentStatus sort order: waiting < pendingWaiting < working < unknown")
    func statusSortOrder() {
        #expect(AgentStatus.waiting.sortOrder < AgentStatus.pendingWaiting.sortOrder)
        #expect(AgentStatus.pendingWaiting.sortOrder < AgentStatus.working.sortOrder)
        #expect(AgentStatus.working.sortOrder < AgentStatus.unknown.sortOrder)
    }

    @Test("AgentStatus display labels")
    func statusDisplayLabels() {
        #expect(AgentStatus.working.displayLabel == "Working")
        #expect(AgentStatus.pendingWaiting.displayLabel == "Working")  // Shows as working
        #expect(AgentStatus.waiting.displayLabel == "Waiting")
        #expect(AgentStatus.unknown.displayLabel == "Unknown")
    }

    // MARK: - AgentSession

    @Test("AgentSession displayStatus hides pendingWaiting")
    func displayStatus() {
        let session = AgentSession(
            sessionId: "1", cwd: "/a", projectName: "a", status: .pendingWaiting, isHookTracked: true)
        #expect(session.displayStatus == .working)

        let waiting = AgentSession(sessionId: "2", cwd: "/b", projectName: "b", status: .waiting, isHookTracked: true)
        #expect(waiting.displayStatus == .waiting)
    }

    @Test("formattedContext formats percentage correctly")
    func formattedContext() {
        let session = AgentSession(sessionId: "1", cwd: "/a", projectName: "a", contextPct: 68.5, isHookTracked: true)
        #expect(session.formattedContext == "68%")

        let noContext = AgentSession(sessionId: "2", cwd: "/b", projectName: "b", isHookTracked: false)
        #expect(noContext.formattedContext == "—")
    }

    @Test("shortModelName extracts model family")
    func shortModelName() {
        let opus = AgentSession(
            sessionId: "1", cwd: "/a", projectName: "a", model: "claude-opus-4-6", isHookTracked: true)
        #expect(opus.shortModelName == "Opus")

        let sonnet = AgentSession(
            sessionId: "2", cwd: "/b", projectName: "b", model: "claude-sonnet-4-6", isHookTracked: true)
        #expect(sonnet.shortModelName == "Sonnet")

        let haiku = AgentSession(
            sessionId: "3", cwd: "/c", projectName: "c", model: "claude-haiku-4-5-20251001", isHookTracked: true)
        #expect(haiku.shortModelName == "Haiku")

        let noModel = AgentSession(sessionId: "4", cwd: "/d", projectName: "d", isHookTracked: false)
        #expect(noModel.shortModelName == "—")
    }

    @Test("AgentSession decodes from JSON state file")
    func decodesFromJSON() throws {
        let json = """
            {
                "session_id": "42ac740e",
                "cwd": "/Users/test/project",
                "project_name": "project",
                "status": "waiting",
                "model": "claude-opus-4-6",
                "git_branch": "main",
                "slug": "test-slug",
                "context_pct": 68.5,
                "started_at": "2026-03-12T08:44:59Z",
                "updated_at": "2026-03-12T09:12:33Z",
                "is_hook_tracked": true
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(
            AgentSession.self, from: json.data(using: .utf8)!  // swiftlint:disable:this force_unwrapping
        )

        #expect(session.sessionId == "42ac740e")
        #expect(session.status == .waiting)
        #expect(session.model == "claude-opus-4-6")
        #expect(session.contextPct == 68.5)
        #expect(session.isHookTracked == true)
    }

    @Test("iterm2SessionId decodes when present")
    func iterm2SessionIdPresent() throws {
        let json = """
            {
                "session_id": "abc123",
                "cwd": "/tmp",
                "project_name": "test",
                "status": "working",
                "is_hook_tracked": true,
                "iterm2_session_id": "w0t0p0.DEADBEEF-1234-5678-9ABC-DEF012345678"
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(
            AgentSession.self, from: json.data(using: .utf8)!  // swiftlint:disable:this force_unwrapping
        )
        #expect(session.iterm2SessionId == "w0t0p0.DEADBEEF-1234-5678-9ABC-DEF012345678")
    }

    @Test("iterm2SessionId is nil when absent")
    func iterm2SessionIdAbsent() throws {
        let json = """
            {
                "session_id": "abc456",
                "cwd": "/tmp",
                "project_name": "test",
                "status": "waiting",
                "is_hook_tracked": true
            }
            """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let session = try decoder.decode(
            AgentSession.self, from: json.data(using: .utf8)!  // swiftlint:disable:this force_unwrapping
        )
        #expect(session.iterm2SessionId == nil)
    }

    @Test("elapsedTime formats hours and minutes")
    func elapsedTime() {
        let recent = AgentSession(
            sessionId: "1", cwd: "/a", projectName: "a",
            startedAt: Date().addingTimeInterval(-300),  // 5 min ago
            isHookTracked: true
        )
        #expect(recent.elapsedTime == "5m")

        let old = AgentSession(
            sessionId: "2", cwd: "/b", projectName: "b",
            startedAt: Date().addingTimeInterval(-7500),  // 2h 5m ago
            isHookTracked: true
        )
        #expect(old.elapsedTime == "2h 5m")

        let noStart = AgentSession(sessionId: "3", cwd: "/c", projectName: "c", isHookTracked: false)
        #expect(noStart.elapsedTime == "—")
    }
}
