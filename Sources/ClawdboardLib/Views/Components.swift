import AppKit
import SwiftUI

// MARK: - Status Display Color

extension AgentStatus {
    /// The color associated with this status for use in labels, dots, and pills.
    public var displayColor: Color {
        switch self {
        case .working, .pendingWaiting: return .blue
        case .needsApproval: return .red
        case .waiting: return .green
        case .abandoned: return .gray.opacity(0.4)
        case .unknown: return .gray
        }
    }
}

// MARK: - Status Dot

/// Colored circle indicating session status. Pulses when working.
public struct StatusDot: View {
    public let status: AgentStatus
    @State private var isPulsing = false

    public init(status: AgentStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(isPulsing ? 0.4 : 1.0)
            .animation(
                shouldPulse
                    ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                isPulsing = shouldPulse
            }
            .onChange(of: status) { _, _ in
                isPulsing = shouldPulse
            }
    }

    private var shouldPulse: Bool {
        status == .needsApproval
    }

    private var color: Color {
        status.displayColor
    }
}

// MARK: - Context Bar

/// Horizontal progress bar showing context window usage percentage.
public struct ContextBar: View {
    public let percentage: Double?

    public init(percentage: Double?) {
        self.percentage = percentage
    }

    public var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.quaternary)

                if let pct = percentage {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor(for: pct))
                        .frame(width: geometry.size.width * min(pct / 100.0, 1.0))
                }
            }
        }
        .frame(height: 4)
    }

    private func barColor(for pct: Double) -> Color {
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .secondary
    }
}

// MARK: - Usage Limits View

/// Compact usage limits display showing both 5-hour and 7-day windows
/// with ring gauges, utilization, average, estimated, and reset time.
public struct UsageLimitsView: View {
    public let limits: UsageLimitsData
    public var error: String?

    public init(limits: UsageLimitsData, error: String? = nil) {
        self.limits = limits
        self.error = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 24) {
                UsageWindowView(label: "5h", window: limits.fiveHour)
                UsageWindowView(label: "7d", window: limits.sevenDay)
            }

            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }
}

/// A single usage window with progress bar and metrics.
struct UsageWindowView: View {
    let label: String
    let window: UsageLimitWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: "%.0f%%", window.utilization))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(barColor)
                Spacer()
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(barColor)
                        .frame(width: geometry.size.width * min(CGFloat(window.utilization / 100), 1))

                    // Estimated usage marker
                    if window.estimated > 0 {
                        let estimatedX =
                            geometry.size.width * min(CGFloat(window.estimated / 100), 1)
                        Rectangle()
                            .fill(Color.primary.opacity(0.4))
                            .frame(width: 1, height: 8)
                            .offset(x: estimatedX)
                    }
                }
            }
            .frame(height: 8)

            HStack {
                Text(String(format: "est %.0f%%", window.estimated))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("resets \(window.remainingText)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var barColor: Color {
        if window.utilization >= 90 { return .red }
        if window.utilization >= 70 { return .orange }
        return .secondary
    }
}

// MARK: - Detail Row

/// Key-value pair for the expanded detail grid.
public struct DetailRow: View {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 60, alignment: .trailing)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - Cursor Rect

/// NSView that uses `addCursorRect` to reliably set the pointing-hand cursor.
/// Unlike `NSCursor.push()`/`pop()` in `.onHover`, cursor rects are managed by
/// AppKit's tracking system and handle nested views correctly.
private class PointingHandCursorView: NSView {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// Wraps `PointingHandCursorView` for use in SwiftUI.
struct PointingHandCursor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = PointingHandCursorView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

extension View {
    /// Adds a pointing-hand cursor when hovering over this view, using AppKit cursor rects.
    func pointingHandCursor() -> some View {
        overlay(PointingHandCursor())
    }
}
