import Foundation
import Testing

@testable import ClawdboardLib

@Suite("AppState")
struct AppStateTests {

    @Test("sortedSessions orders by urgency: waiting > working > unknown")
    func sortedSessionsByUrgency() {
        let state = AppState()
        let now = Date()
        state.sessions = [
            AgentSession(
                sessionId: "1", cwd: "/a", projectName: "a", status: .working, updatedAt: now, isHookTracked: true),
            AgentSession(sessionId: "2", cwd: "/b", projectName: "b", status: .unknown, isHookTracked: false),
            AgentSession(
                sessionId: "3", cwd: "/c", projectName: "c", status: .waiting, updatedAt: now, isHookTracked: true),
        ]

        let sorted = state.sortedSessions
        #expect(sorted[0].sessionId == "3")  // waiting first
        #expect(sorted[1].sessionId == "1")  // working second
        #expect(sorted[2].sessionId == "2")  // unknown last
    }

    @Test("waitingCount counts only waiting sessions")
    func waitingCount() {
        let state = AppState()
        state.sessions = [
            AgentSession(sessionId: "1", cwd: "/a", projectName: "a", status: .working, isHookTracked: true),
            AgentSession(sessionId: "2", cwd: "/b", projectName: "b", status: .waiting, isHookTracked: true),
            AgentSession(sessionId: "3", cwd: "/c", projectName: "c", status: .waiting, isHookTracked: true),
        ]
        #expect(state.waitingCount == 2)
    }

    @Test("workingCount counts working and pending_waiting sessions")
    func workingCount() {
        let state = AppState()
        state.sessions = [
            AgentSession(sessionId: "1", cwd: "/a", projectName: "a", status: .working, isHookTracked: true),
            AgentSession(sessionId: "2", cwd: "/b", projectName: "b", status: .pendingWaiting, isHookTracked: true),
            AgentSession(sessionId: "3", cwd: "/c", projectName: "c", status: .waiting, isHookTracked: true),
        ]
        // pending_waiting displays as working
        #expect(state.workingCount == 2)
    }

    @Test("totalCost sums all session costs")
    func totalCost() {
        let state = AppState()
        state.sessions = [
            AgentSession(sessionId: "1", cwd: "/a", projectName: "a", costUsd: 1.50, isHookTracked: true),
            AgentSession(sessionId: "2", cwd: "/b", projectName: "b", costUsd: 2.25, isHookTracked: true),
            AgentSession(sessionId: "3", cwd: "/c", projectName: "c", isHookTracked: false),  // nil cost
        ]
        #expect(state.totalCost == 3.75)
    }

    @Test("toggleExpanded toggles session expansion")
    func toggleExpanded() {
        let state = AppState()
        #expect(state.expandedSessionId == nil)

        state.toggleExpanded(sessionId: "abc")
        #expect(state.expandedSessionId == "abc")

        state.toggleExpanded(sessionId: "abc")
        #expect(state.expandedSessionId == nil)

        state.toggleExpanded(sessionId: "abc")
        state.toggleExpanded(sessionId: "def")
        #expect(state.expandedSessionId == "def")
    }
}
