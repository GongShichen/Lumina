import SwiftUI

struct AgentRunTimelineView: View {
    let items: [AgentRunTimelineItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.systemImage)
                        .foregroundStyle(color(for: item.status))
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(.callout)
                        if let detail = item.detail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func color(for status: AgentRunTimelineItem.TimelineStatus) -> Color {
        switch status {
        case .active:
            return .accentColor
        case .success:
            return .green
        case .warning:
            return .orange
        case .failure:
            return .red
        case .info:
            return .secondary
        }
    }
}

