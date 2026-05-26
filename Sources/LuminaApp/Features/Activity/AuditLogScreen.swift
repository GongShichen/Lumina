import LuminaAgentClient
import SwiftUI

struct AuditLogScreen: View {
    let timelineItems: [AgentRunTimelineItem]
    let auditRecords: [LuminaAuditRecord]

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LuminaSectionHeader(title: "Activity", subtitle: "Lumina 为你做过什么，都能回看")

                    HStack(spacing: 10) {
                        LuminaMetricTile(title: "Privacy", value: "Local", caption: "Only this iPhone", tint: LuminaTheme.mint)
                        LuminaMetricTile(title: "Permission", value: "Ask", caption: "Before changes", tint: LuminaTheme.amber)
                        LuminaMetricTile(title: "Undo", value: "When", caption: "Possible", tint: LuminaTheme.aqua)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        if !timelineItems.isEmpty {
                            ForEach(timelineItems) { item in
                                AuditRow(
                                    time: "live",
                                    decision: item.status.rawValue.uppercased(),
                                    tool: item.title,
                                    detail: item.detail ?? "event recorded",
                                    status: item.status
                                )
                            }
                        } else if auditRecords.isEmpty {
                            Text("暂无审计记录")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 18)
                        } else {
                            ForEach(auditRecords, id: \.id) { record in
                                AuditRow(record: record)
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
    }
}
