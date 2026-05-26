import SwiftUI

struct AgentRunTimelineView: View {
    let items: [AgentRunTimelineItem]

    private var visibleItems: [AgentRunTimelineItem] {
        Array(items.suffix(6))
    }

    var body: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    LuminaSectionHeader(title: "正在处理", subtitle: "每一步都会留下可解释记录")
                    Spacer()
                    Text("\(items.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LuminaTheme.deepInk)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(LuminaTheme.amber.opacity(0.24), in: Capsule())
                }

                VStack(alignment: .leading, spacing: 0) {
                    if items.count > visibleItems.count {
                        Text("已折叠前 \(items.count - visibleItems.count) 步，完整记录可在 Activity 查看。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.bottom, 6)
                    }
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        HStack(alignment: .top, spacing: 11) {
                            VStack(spacing: 0) {
                                Image(systemName: item.systemImage)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(color(for: item.status))
                                    .frame(width: 26, height: 26)
                                    .background(color(for: item.status).opacity(0.12), in: Circle())
                                if index < visibleItems.count - 1 {
                                    Rectangle()
                                        .fill(color(for: item.status).opacity(0.20))
                                        .frame(width: 2, height: 24)
                                }
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle(for: item.title))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(LuminaTheme.ink)
                                if let detail = item.detail, !detail.isEmpty {
                                    Text(displayDetail(for: detail))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
    }

    private func color(for status: AgentRunTimelineItem.TimelineStatus) -> Color {
        switch status {
        case .active:
            return LuminaTheme.blue
        case .success:
            return LuminaTheme.mint
        case .warning:
            return LuminaTheme.amber
        case .failure:
            return LuminaTheme.red
        case .info:
            return .secondary
        }
    }

    private func displayTitle(for title: String) -> String {
        if title.localizedCaseInsensitiveContains("thought") || title.contains("模型") || title.contains("准备") {
            return "Thinking"
        }
        if title.localizedCaseInsensitiveContains("tool") || title.contains("工具") || title.contains("Action") {
            return "Checking the right tool"
        }
        if title.localizedCaseInsensitiveContains("observation") || title.contains("Observation") {
            return "Reading local context"
        }
        if title.localizedCaseInsensitiveContains("final") || title.contains("完成") {
            return "Done"
        }
        return title
    }

    private func displayDetail(for detail: String) -> String {
        detail
            .replacingOccurrences(of: "stepGenerator/tool", with: "Lumina")
            .replacingOccurrences(of: "schema", with: "permission details")
            .replacingOccurrences(of: "ReAct", with: "steps")
    }
}
