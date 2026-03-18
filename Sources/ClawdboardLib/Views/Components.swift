import SwiftUI

// MARK: - Status Display Color

extension AgentStatus {
    /// The color associated with this status for use in labels, dots, and pills.
    public var displayColor: Color {
        switch self {
        case .working, .pendingWaiting: return .green
        case .needsApproval: return .red
        case .waiting: return .orange
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
        return .green
    }
}

// MARK: - Usage Limits View

/// Compact usage limits display showing both 5-hour and 7-day windows
/// with ring gauges, utilization, average, estimated, and reset time.
public struct UsageLimitsView: View {
    public let limits: UsageLimitsData
    public var error: String?
    public var onRefresh: (() -> Void)?

    public init(limits: UsageLimitsData, error: String? = nil, onRefresh: (() -> Void)? = nil) {
        self.limits = limits
        self.error = error
        self.onRefresh = onRefresh
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                UsageWindowView(label: "5h", window: limits.fiveHour)
                Divider().frame(height: 44)
                UsageWindowView(label: "7d", window: limits.sevenDay)
            }

            HStack(spacing: 4) {
                Text("Updated \(updatedText)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                if let onRefresh {
                    Button(action: onRefresh) {
                        Image(systemName: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }

                if let error {
                    Spacer()
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }

    private var updatedText: String {
        let interval = Date().timeIntervalSince(limits.updatedAt)
        if interval < 5 { return "just now" }
        if interval < 60 { return "\(Int(interval))s ago" }
        let minutes = Int(interval / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        return "\(hours)h ago"
    }
}

/// A single usage window with ring gauge and metrics.
struct UsageWindowView: View {
    let label: String
    let window: UsageLimitWindow

    var body: some View {
        HStack(spacing: 8) {
            // Ring gauge
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 3)
                Circle()
                    .trim(from: 0, to: CGFloat(min(window.utilization / 100, 1)))
                    .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(String(format: "%.0f%%", window.utilization))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
            }
            .frame(width: 36, height: 36)

            // Metrics
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(String(format: "~%.0f%% est", window.estimated))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("resets \(window.remainingText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ringColor: Color {
        if window.utilization >= 90 { return .red }
        if window.utilization >= 70 { return .orange }
        return .green
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
