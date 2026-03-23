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

/// Colored circle indicating session status.
public struct StatusDot: View {
    public let status: AgentStatus

    public init(status: AgentStatus) {
        self.status = status
    }

    public var body: some View {
        Circle()
            .fill(status.displayColor)
            .frame(width: 8, height: 8)
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

// MARK: - PR Status Icon

/// Displays the pull request status for a session's branch using
/// custom-drawn GitHub-style icons. Falls back to commit badge when
/// no PR exists but commits were made during the session.
public struct PRStatusIcon: View {
    public let prInfo: PRInfo?
    public var commitCount: Int?
    public var unpushedCount: Int?
    public var commitCompareUrl: String?

    @State private var isHovered = false

    private static let iconSize: CGFloat = 14
    private static let badgeSize: CGFloat = 24

    private var status: PRStatus? { prInfo?.status }

    /// Whether to show the commit badge instead of PR icon
    private var showCommitBadge: Bool {
        let noPR = status == nil || status == .none
        return noPR && (commitCount ?? 0) > 0
    }

    private var commitColor: Color {
        switch unpushedCount {
        case .some(0): return .green  // all pushed
        case .some: return .orange  // has unpushed
        case .none: return .secondary  // no upstream
        }
    }

    private var iconColor: Color {
        if showCommitBadge { return commitColor }
        switch status {
        case .some(.open): return .green
        case .some(.merged): return .purple
        case .some(.closed): return .secondary
        case .some(.none), nil: return .secondary
        }
    }

    private var hasBadge: Bool {
        if showCommitBadge { return true }
        switch status {
        case .some(.open), .some(.merged), .some(.closed): return true
        default: return false
        }
    }

    private var clickUrl: URL? {
        if showCommitBadge {
            return commitCompareUrl.flatMap { URL(string: $0) }
        }
        return prInfo?.url.flatMap { URL(string: $0) }
    }

    private var isClickable: Bool { clickUrl != nil }

    /// Minimum badge width — wider for commit count text
    private var badgeWidth: CGFloat {
        if showCommitBadge {
            let count = commitCount ?? 0
            if count >= 10 { return 30 }
            return Self.badgeSize
        }
        return Self.badgeSize
    }

    public var body: some View {
        Group {
            if showCommitBadge {
                commitBadgeContent
            } else {
                prBadgeContent
            }
        }
        .frame(minWidth: badgeWidth, minHeight: Self.badgeSize)
        .fixedSize()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hasBadge ? iconColor.opacity(isHovered ? 0.22 : 0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    hasBadge ? iconColor.opacity(isHovered ? 0.5 : 0.3) : .clear,
                    lineWidth: 0.5)
        )
        .overlay(
            hasBadge
                ? nil
                : RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .foregroundStyle(.tertiary)
                    .padding(1.5)
        )
        .onHover { isHovered = isClickable ? $0 : false }
        .pointingHandCursor(enabled: isClickable)
        .onTapGesture {
            if let clickUrl { NSWorkspace.shared.open(clickUrl) }
        }
        .animation(.easeInOut(duration: 0.1), value: isHovered)
    }

    @ViewBuilder
    private var commitBadgeContent: some View {
        HStack(spacing: 2) {
            SVGPathShape(svgPath: PhosphorPaths.gitCommit, viewBox: 256)
                .foregroundStyle(commitColor)
                .frame(width: 10, height: 10)
            Text("\(commitCount ?? 0)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(commitColor)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var prBadgeContent: some View {
        Group {
            switch status {
            case .some(.open):
                PROpenIcon()
                    .foregroundStyle(.green)
            case .some(.merged):
                PRMergedIcon()
                    .foregroundStyle(.purple)
            case .some(.closed):
                PRClosedIcon()
                    .foregroundStyle(.secondary)
            case .some(.none), nil:
                Color.clear
            }
        }
        .frame(width: Self.iconSize, height: Self.iconSize)
        .frame(width: Self.badgeSize, height: Self.badgeSize)
    }
}

// MARK: - GitHub-style PR Icon Shapes

/// Phosphor Icons SVG path data (viewBox 0 0 256 256).
private enum PhosphorPaths {
    // swiftlint:disable line_length
    static let gitPullRequest =
        "M104,64A32,32,0,1,0,64,95v66a32,32,0,1,0,16,0V95A32.06,32.06,0,0,0,104,64ZM56,64A16,16,0,1,1,72,80,16,16,0,0,1,56,64ZM88,192a16,16,0,1,1-16-16A16,16,0,0,1,88,192Zm120-31V110.63a23.85,23.85,0,0,0-7-17L163.31,56H192a8,8,0,0,0,0-16H144a8,8,0,0,0-8,8V96a8,8,0,0,0,16,0V67.31L189.66,105a8,8,0,0,1,2.34,5.66V161a32,32,0,1,0,16,0Zm-8,47a16,16,0,1,1,16-16A16,16,0,0,1,200,208Z"
    static let gitMerge =
        "M208,112a32.05,32.05,0,0,0-30.69,23l-42.21-6a8,8,0,0,1-4.95-2.71L94.43,84.55A32,32,0,1,0,72,87v82a32,32,0,1,0,16,0V101.63l30,35a24,24,0,0,0,14.83,8.14l44,6.28A32,32,0,1,0,208,112ZM64,56A16,16,0,1,1,80,72,16,16,0,0,1,64,56ZM96,200a16,16,0,1,1-16-16A16,16,0,0,1,96,200Zm112-40a16,16,0,1,1,16-16A16,16,0,0,1,208,160Z"
    // Phosphor git-commit (bold) — horizontal line with circle node
    static let gitCommit =
        "M248,120H175.3a48,48,0,0,0-94.6,0H8a8,8,0,0,0,0,16H80.7a48,48,0,0,0,94.6,0H248a8,8,0,0,0,0-16ZM128,160a32,32,0,1,1,32-32A32,32,0,0,1,128,160Z"
    // swiftlint:enable line_length
}

/// Open PR icon — Phosphor Icons git-pull-request SVG path rendered as a filled shape.
private struct PROpenIcon: View {
    var body: some View {
        SVGPathShape(svgPath: PhosphorPaths.gitPullRequest, viewBox: 256)
    }
}

/// Renders an SVG path string as a filled SwiftUI shape, scaled to fit.
private struct SVGPathShape: View, Shape {
    let svgPath: String
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let cgPath = CGMutablePath()
        parseSVGPath(svgPath, into: cgPath)
        var transform = CGAffineTransform(scaleX: scale, y: scale)
        guard let scaled = cgPath.copy(using: &transform) else {
            return Path(cgPath)
        }
        return Path(scaled)
    }
}

/// Parse a subset of SVG path `d` attribute into a CGMutablePath.
/// Supports M, m, L, l, H, h, V, v, A, a, Z, z commands.
private func parseSVGPath(_ d: String, into path: CGMutablePath) {
    let chars = Array(d)
    var idx = 0
    var currentX: CGFloat = 0
    var currentY: CGFloat = 0
    var lastCommand: Character = " "

    func skipWhitespaceAndCommas() {
        while idx < chars.count && (chars[idx] == " " || chars[idx] == "," || chars[idx] == "\n") {
            idx += 1
        }
    }

    func parseNumber() -> CGFloat? {
        skipWhitespaceAndCommas()
        guard idx < chars.count else { return nil }
        var numStr = ""
        if chars[idx] == "-" || chars[idx] == "+" {
            numStr.append(chars[idx])
            idx += 1
        }
        var hasDot = false
        while idx < chars.count {
            let c = chars[idx]
            if c.isNumber {
                numStr.append(c)
                idx += 1
            } else if c == "." && !hasDot {
                hasDot = true
                numStr.append(c)
                idx += 1
            } else {
                break
            }
        }
        // Handle cases like "16-16" (two numbers without separator)
        return numStr.isEmpty ? nil : CGFloat(Double(numStr) ?? 0)
    }

    func parseCoordPair() -> CGPoint? {
        guard let x = parseNumber(), let y = parseNumber() else { return nil }
        return CGPoint(x: x, y: y)
    }

    while idx < chars.count {
        skipWhitespaceAndCommas()
        guard idx < chars.count else { break }

        var cmd = chars[idx]
        if cmd.isLetter {
            idx += 1
            lastCommand = cmd
        } else {
            // Implicit repeat of last command
            cmd = lastCommand
        }

        switch cmd {
        case "M":
            guard let pt = parseCoordPair() else { break }
            path.move(to: pt)
            currentX = pt.x
            currentY = pt.y
            lastCommand = "L"  // subsequent coords are lineTo
        case "m":
            guard let pt = parseCoordPair() else { break }
            currentX += pt.x
            currentY += pt.y
            path.move(to: CGPoint(x: currentX, y: currentY))
            lastCommand = "l"
        case "L":
            guard let pt = parseCoordPair() else { break }
            path.addLine(to: pt)
            currentX = pt.x
            currentY = pt.y
        case "l":
            guard let pt = parseCoordPair() else { break }
            currentX += pt.x
            currentY += pt.y
            path.addLine(to: CGPoint(x: currentX, y: currentY))
        case "H":
            guard let x = parseNumber() else { break }
            path.addLine(to: CGPoint(x: x, y: currentY))
            currentX = x
        case "h":
            guard let dx = parseNumber() else { break }
            currentX += dx
            path.addLine(to: CGPoint(x: currentX, y: currentY))
        case "V":
            guard let y = parseNumber() else { break }
            path.addLine(to: CGPoint(x: currentX, y: y))
            currentY = y
        case "v":
            guard let dy = parseNumber() else { break }
            currentY += dy
            path.addLine(to: CGPoint(x: currentX, y: currentY))
        case "A", "a":
            let relative = cmd == "a"
            guard let rx = parseNumber(),
                let ry = parseNumber(),
                parseNumber() != nil,  // x-axis rotation (unused for circles)
                let largeArc = parseNumber(),
                let sweep = parseNumber(),
                let ex = parseNumber(),
                let ey = parseNumber()
            else { break }

            let endX = relative ? currentX + ex : ex
            let endY = relative ? currentY + ey : ey

            // Convert SVG arc to center parameterization for addArc
            addSVGArc(
                to: path, from: CGPoint(x: currentX, y: currentY),
                to: CGPoint(x: endX, y: endY),
                rx: rx, ry: ry,
                largeArc: largeArc != 0, sweep: sweep != 0)

            currentX = endX
            currentY = endY
        case "Z", "z":
            path.closeSubpath()
        default:
            idx += 1  // skip unknown
        }
    }
}

/// Convert SVG arc parameters to CGPath arc.
private func addSVGArc(
    to path: CGMutablePath,
    from start: CGPoint, to end: CGPoint,
    rx: CGFloat, ry: CGFloat,
    largeArc: Bool, sweep: Bool
) {
    // For equal rx/ry (circles), use the standard center-arc conversion
    let r = max(rx, ry)
    guard r > 0 else {
        path.addLine(to: end)
        return
    }

    let dx = (start.x - end.x) / 2
    let dy = (start.y - end.y) / 2
    let d2 = dx * dx + dy * dy
    let r2 = r * r

    // Clamp radius if needed
    let actualR = d2 > r2 ? sqrt(d2) : r

    let sr2 = actualR * actualR
    let sq = max(0, (sr2 - d2) / d2)
    let sign: CGFloat = (largeArc == sweep) ? -1 : 1
    let factor = sign * sqrt(sq)

    let cx = (start.x + end.x) / 2 + factor * dy
    let cy = (start.y + end.y) / 2 - factor * dx

    let startAngle = atan2(start.y - cy, start.x - cx)
    let endAngle = atan2(end.y - cy, end.x - cx)

    // SVG sweep=1 means clockwise, but CGPath clockwise param is inverted (flipped Y)
    path.addArc(
        center: CGPoint(x: cx, y: cy), radius: actualR,
        startAngle: startAngle, endAngle: endAngle,
        clockwise: !sweep)
}

/// Merged PR icon — Phosphor Icons git-merge SVG path rendered as a filled shape.
private struct PRMergedIcon: View {
    var body: some View {
        SVGPathShape(svgPath: PhosphorPaths.gitMerge, viewBox: 256)
    }
}

/// Closed PR icon: reuses the open PR shape (same visual structure).
private struct PRClosedIcon: View {
    var body: some View {
        SVGPathShape(svgPath: PhosphorPaths.gitPullRequest, viewBox: 256)
    }
}

// DashedCircleIcon removed — "no PR" state now uses a dashed rounded rectangle overlay

// MARK: - Sparkline View

/// Miniature activity chart showing context usage rate over a 2-hour window.
/// Plots context_pct deltas per minute bucket — peaks = active generation, flat = idle.
public struct SparklineView: View {
    public let snapshots: [ContextSnapshot]
    public var approvalTimestamps: [Date] = []

    private static let windowMinutes = 120
    private static let bucketCount = 60  // one bucket per 2 minutes
    private static let redrawInterval: TimeInterval = 30

    /// Periodic tick to force redraw so the time window slides even when no new data arrives.
    @State private var tick = false
    private let timer = Timer.publish(every: redrawInterval, on: .main, in: .common).autoconnect()

    public init(snapshots: [ContextSnapshot], approvalTimestamps: [Date] = []) {
        self.snapshots = snapshots
        self.approvalTimestamps = approvalTimestamps
    }

    public var body: some View {
        // tick is read here so SwiftUI tracks it as a dependency
        let _ = tick
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
        .frame(width: 130, height: 24)
        .onReceive(timer) { _ in tick.toggle() }
    }

    /// Compute activity (context_pct delta) per 2-minute bucket over the last 2 hours.
    private var activityBuckets: [Double] {
        guard snapshots.count >= 2 else { return [] }

        let now = Date()
        let windowStart = now.addingTimeInterval(
            -Double(Self.windowMinutes * 60))
        let bucketDuration = Double(Self.windowMinutes * 60) / Double(Self.bucketCount)

        // Filter to last 2 hours
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
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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
    func pointingHandCursor(enabled: Bool = true) -> some View {
        overlay(enabled ? PointingHandCursor() : nil)
    }
}
