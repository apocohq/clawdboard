import SwiftUI

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
        status == .working || status == .needsApproval
    }

    private var color: Color {
        switch status {
        case .working, .pendingWaiting: return .green
        case .needsApproval: return .red
        case .waiting: return .orange
        case .abandoned: return .gray.opacity(0.4)
        case .unknown: return .gray
        }
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
        if pct >= 80 { return .red }
        if pct >= 60 { return .orange }
        return .blue
    }
}

// MARK: - Usage Limits View

/// Compact usage limits display showing both 5-hour and 7-day windows
/// with ring gauges, utilization, average, estimated, and reset time.
public struct UsageLimitsView: View {
    public let limits: UsageLimitsData

    public init(limits: UsageLimitsData) {
        self.limits = limits
    }

    public var body: some View {
        HStack(spacing: 12) {
            UsageWindowView(label: "5h", window: limits.fiveHour)
            Divider().frame(height: 40)
            UsageWindowView(label: "7d", window: limits.sevenDay)
        }
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
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
            }
            .frame(width: 32, height: 32)

            // Metrics
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    Text(String(format: "~%.0f%% est", window.estimated))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text("resets \(window.remainingText)")
                    .font(.caption2.monospacedDigit())
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
