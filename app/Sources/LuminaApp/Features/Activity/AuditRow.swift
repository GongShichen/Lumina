import LuminaAgentRuntime
import SwiftUI

struct AuditRow: View {
    let time: String
    let decision: String
    let tool: String
    let detail: String
    let status: AgentRunTimelineItem.TimelineStatus

    init(
        time: String,
        decision: String,
        tool: String,
        detail: String,
        status: AgentRunTimelineItem.TimelineStatus
    ) {
        self.time = time
        self.decision = decision
        self.tool = tool
        self.detail = detail
        self.status = status
    }

    init(record: LuminaAuditRecord) {
        self.time = AuditRow.formatter.string(from: record.timestamp)
        self.decision = record.resultStatus.rawValue.uppercased()
        self.tool = record.toolName
        self.detail = record.errorMessage ?? record.outputSummary
        switch record.resultStatus {
        case .succeeded:
            self.status = .success
        case .denied:
            self.status = .warning
        case .cancelled:
            self.status = .warning
        case .failed:
            self.status = .failure
        }
    }

    var body: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(time)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(decision)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.10), in: Capsule())
                }
                Text(tool)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        }
    }

    private var color: Color {
        switch status {
        case .active: return LuminaTheme.blue
        case .success: return LuminaTheme.mint
        case .warning: return LuminaTheme.amber
        case .failure: return LuminaTheme.red
        case .info: return .secondary
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
