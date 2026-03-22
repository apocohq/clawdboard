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

// MARK: - Sparkline View

/// Miniature activity chart showing context usage rate over a 30-minute window.
/// Plots context_pct deltas per minute bucket — peaks = active generation, flat = idle.
public struct SparklineView: View {
    public let snapshots: [ContextSnapshot]
    public var approvalTimestamps: [Date] = []

    private static let windowMinutes = 30
    private static let bucketCount = 30  // one bucket per minute

    public init(snapshots: [ContextSnapshot], approvalTimestamps: [Date] = []) {
        self.snapshots = snapshots
        self.approvalTimestamps = approvalTimestamps
    }

    public var body: some View {
        Canvas { context, size in
            let windowStart = Date().addingTimeInterval(
                -Double(Self.windowMinutes * 60))
            let windowDuration = Double(Self.windowMinutes * 60)

            let buckets = activityBuckets
            guard buckets.count >= 2 else {
                // Empty baseline
                var baseline = Path()
                baseline.move(to: CGPoint(x: 0, y: size.height - 0.5))
                baseline.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                context.stroke(baseline, with: .color(.gray.opacity(0.2)), lineWidth: 1)
                return
            }

            let maxVal = max(buckets.max() ?? 1, 0.1)  // avoid division by zero

            let points: [CGPoint] = buckets.enumerated().map { index, value in
                let x = size.width * CGFloat(index) / CGFloat(buckets.count - 1)
                let y = size.height * (1 - CGFloat(value / maxVal))
                return CGPoint(x: x, y: y)
            }

            var linePath = Path()
            linePath.move(to: points[0])
            for point in points.dropFirst() {
                linePath.addLine(to: point)
            }
            context.stroke(linePath, with: .color(strokeColor), lineWidth: 1)

            // Fill under the line
            var fillPath = linePath
            fillPath.addLine(to: CGPoint(x: points.last!.x, y: size.height))
            fillPath.addLine(to: CGPoint(x: points.first!.x, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .color(strokeColor.opacity(0.15)))

            // Red dots for approval events within the window
            let dotRadius: CGFloat = 1.0
            for timestamp in approvalTimestamps {
                guard timestamp >= windowStart else { continue }
                let xPct = timestamp.timeIntervalSince(windowStart) / windowDuration
                let x = size.width * CGFloat(xPct)
                // Place dot on the line by interpolating the bucket value
                let bucketIndex = xPct * Double(Self.bucketCount - 1)
                let lowerIdx = min(Int(bucketIndex), Self.bucketCount - 2)
                let frac = bucketIndex - Double(lowerIdx)
                let value = buckets[lowerIdx] * (1 - frac) + buckets[lowerIdx + 1] * frac
                let y = size.height * (1 - CGFloat(value / maxVal))
                let dot = CGRect(
                    x: x - dotRadius, y: y - dotRadius,
                    width: dotRadius * 2, height: dotRadius * 2)
                context.fill(Path(ellipseIn: dot), with: .color(.red))
            }
        }
        .frame(width: 80, height: 16)
    }

    /// Compute activity (context_pct delta) per minute bucket over the last 30 minutes.
    private var activityBuckets: [Double] {
        guard snapshots.count >= 2 else { return [] }

        let now = Date()
        let windowStart = now.addingTimeInterval(
            -Double(Self.windowMinutes * 60))
        let bucketDuration = Double(Self.windowMinutes * 60) / Double(Self.bucketCount)

        // Filter to last 30 minutes
        let recent = snapshots.filter { $0.t >= windowStart }
        guard recent.count >= 2 else { return [] }

        // For each bucket, sum the positive context_pct deltas between consecutive snapshots
        var buckets = [Double](repeating: 0, count: Self.bucketCount)

        for i in 1..<recent.count {
            let delta = max(recent[i].pct - recent[i - 1].pct, 0)  // only positive deltas (activity)
            let bucketIndex = Int(recent[i].t.timeIntervalSince(windowStart) / bucketDuration)
            let clampedIndex = min(max(bucketIndex, 0), Self.bucketCount - 1)
            buckets[clampedIndex] += delta
        }

        return buckets
    }

    /// Color based on the most recent snapshot value, matching ContextBar thresholds.
    private var strokeColor: Color {
        guard let last = snapshots.last else { return .secondary }
        if last.pct >= 90 { return .red }
        if last.pct >= 70 { return .orange }
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
