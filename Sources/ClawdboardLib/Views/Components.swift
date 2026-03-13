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
