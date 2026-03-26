import ApplicationServices
import Foundation

/// Polls stored AXUIElement references to detect when a user renames
/// a terminal tab in JetBrains IDE, propagating the new title back.
///
/// After `focusJetBrainsTerminalTab` finds and clicks a tab, it calls
/// `track(sessionId:element:)` to store the AXUIElement reference.
/// A 3-second timer reads each element's current AXValue — if it changed,
/// the `onChange` callback fires with the new title.
///
/// Follows the `DiffStatsProvider` pattern: serial queue, periodic poll,
/// callback to main thread.
public class TerminalTabPoller {

    // MARK: - Callback

    /// Called on main queue when a tracked tab's title changes.
    /// Parameters: (sessionId, newTitle)
    private let onChange: (String, String) -> Void

    // MARK: - Serial queue protecting all mutable state

    private let queue = DispatchQueue(label: "clawdboard.terminal-tab-poller", qos: .utility)

    /// Tracked tabs: sessionId → (element, lastKnownValue)
    private var tracked: [String: (element: AXUIElement, lastValue: String)] = [:]
    private var pollTimer: DispatchSourceTimer?

    // MARK: - Init

    public init(onChange: @escaping (String, String) -> Void) {
        self.onChange = onChange
    }

    // MARK: - Public API

    /// Start tracking a tab element for rename detection.
    public func track(sessionId: String, element: AXUIElement) {
        let currentValue = AccessibilityHelper.readValue(of: element) ?? ""
        queue.async {
            self.tracked[sessionId] = (element, currentValue)
            if self.pollTimer == nil {
                self.startTimer()
            }
        }
    }

    /// Stop tracking a session (e.g., session ended).
    public func untrack(sessionId: String) {
        queue.async {
            self.tracked.removeValue(forKey: sessionId)
            if self.tracked.isEmpty {
                self.stopTimer()
            }
        }
    }

    /// Remove sessions that are no longer present.
    public func pruneExcept(activeSessionIds: Set<String>) {
        queue.async {
            self.tracked = self.tracked.filter { activeSessionIds.contains($0.key) }
            if self.tracked.isEmpty {
                self.stopTimer()
            }
        }
    }

    // MARK: - Timer

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 3, repeating: 3)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    private func stopTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func poll() {
        var changes: [(String, String)] = []

        for (sessionId, entry) in tracked {
            guard let currentValue = AccessibilityHelper.readValue(of: entry.element) else {
                // Element is stale (tab closed/recreated)
                tracked.removeValue(forKey: sessionId)
                continue
            }
            if currentValue != entry.lastValue {
                tracked[sessionId] = (entry.element, currentValue)
                changes.append((sessionId, currentValue))
            }
        }

        if tracked.isEmpty {
            stopTimer()
        }

        if !changes.isEmpty {
            DispatchQueue.main.async { [onChange] in
                for (sessionId, newTitle) in changes {
                    onChange(sessionId, newTitle)
                }
            }
        }
    }
}
