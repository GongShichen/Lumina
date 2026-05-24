import SwiftUI

struct AgentExecutionStatusView: View {
    let snapshot: LuminaAgentActivitySnapshot
    let items: [AgentRunTimelineItem]

    @State private var isExpanded = false
    @State private var expandedGroups: Set<String> = []

    private var groups: [(String, String, String, Color, [AgentRunTimelineItem])] {
        [
            ("Thinking", "brain.head.profile", "思考与计划", LuminaTheme.aqua, items.filter { matches($0, words: ["规划", "思考", "计划", "准备", "Thinking", "ReAct"]) }),
            ("Permission", "lock.shield", "权限与确认", LuminaTheme.amber, items.filter { matches($0, words: ["权限", "确认", "等待"]) }),
            ("Tool Calls", "hammer", "工具调用", LuminaTheme.mint, items.filter { matches($0, words: ["工具", "动作", "Action", "local.", "calendar.", "reminder."]) }),
            ("Observations", "eye", "观察结果", LuminaTheme.lavender, items.filter { matches($0, words: ["观察", "Observation", "读取", "完成"]) }),
            ("Final", "text.badge.checkmark", "最终回复", LuminaTheme.rose, items.filter { matches($0, words: ["运行结束", "Done"]) })
        ].filter { !$0.4.isEmpty }
    }

    var body: some View {
        LuminaPanel(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        isExpanded.toggle()
                    }
                } label: {
                    compactHeader
                }
                .buttonStyle(.plain)

                if isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(groups, id: \.0) { group in
                            groupRow(
                                title: group.0,
                                systemImage: group.1,
                                subtitle: group.2,
                                tint: group.3,
                                rows: group.4
                            )
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    private var compactHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(LuminaTheme.amber.opacity(0.24), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(0.08, snapshot.progress))
                    .stroke(LuminaTheme.amber, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: iconName)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(snapshot.state == .idle ? "执行记录" : "正在执行")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(LuminaTheme.amber)
                    if snapshot.isLocalOnly {
                        Label("本机处理", systemImage: "lock.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LuminaTheme.mint)
                    }
                }
                Text(snapshot.title)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let toolName = snapshot.toolName {
                        Text(toolName)
                            .font(.caption.monospaced().weight(.semibold))
                            .foregroundStyle(LuminaTheme.aqua)
                    }
                    Text(snapshot.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 5) {
                Text("\(Int(snapshot.progress * 100))%")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(LuminaTheme.softAmber.opacity(0.34), in: Capsule())
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
            }
        }
        .padding(14)
        .contentShape(Rectangle())
    }

    private var iconName: String {
        switch snapshot.state {
        case .idle:
            return "sparkles"
        case .running:
            return "waveform.path.ecg"
        case .waitingForConfirmation:
            return "person.crop.circle.badge.questionmark"
        case .succeeded:
            return "checkmark"
        case .failed:
            return "exclamationmark"
        case .cancelled:
            return "stop.fill"
        }
    }

    private func groupRow(
        title: String,
        systemImage: String,
        subtitle: String,
        tint: Color,
        rows: [AgentRunTimelineItem]
    ) -> some View {
        let isOpen = expandedGroups.contains(title)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    if isOpen {
                        expandedGroups.remove(title)
                    } else {
                        expandedGroups.insert(title)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(LuminaTheme.ink)
                        Text(summary(for: rows) ?? subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text("\(rows.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(tint)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(11)
                .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LuminaTheme.ink)
                            if let detail = item.detail, !detail.isEmpty {
                                Text(detail)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.leading, 38)
                    }
                }
                .padding(.vertical, 9)
                .transition(.opacity)
            }
        }
    }

    private func summary(for rows: [AgentRunTimelineItem]) -> String? {
        rows.last.flatMap { item in
            item.detail?.isEmpty == false ? item.detail : item.title
        }
    }

    private func matches(_ item: AgentRunTimelineItem, words: [String]) -> Bool {
        let value = "\(item.title) \(item.detail ?? "")"
        return words.contains { value.localizedCaseInsensitiveContains($0) }
    }
}
