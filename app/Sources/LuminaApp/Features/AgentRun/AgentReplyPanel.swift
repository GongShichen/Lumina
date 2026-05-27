import LuminaAgentRuntime
import Foundation
import LuminaMarkdownUI
import SwiftUI

struct AgentReplyPanel: View {
    let markdown: String
    let content: [LuminaAgentContentPart]
    let runSummary: LuminaAgentRunSummary?
    let modelReadiness: LuminaModelReadinessSnapshot
    let isRunning: Bool
    let rerunWithModel: () -> Void

    @State private var expandedSections: Set<String> = []

    var body: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 14) {
                header
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(isRunning ? "我正在理解你的请求，并只取必要的本地上下文。" : "还没有回复结果。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 12)
                } else {
                    MarkdownView(markdown: markdown)
                }
                fallbackFooter
                if let runSummary {
                    disclosure(
                        id: "Sources",
                        title: "Sources",
                        subtitle: runSummary.sourceCount == 0 ? "没有引用来源" : "\(runSummary.sourceCount) 条来源",
                        systemImage: "link",
                        tint: LuminaTheme.mint
                    ) {
                        Text(runSummary.sourceCount == 0 ? "本次回复没有注入本地检索引用。" : "来源引用已保留在工具详情和 Activity 记录中。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    disclosure(
                        id: "Tool Details",
                        title: "Tool Details",
                        subtitle: runSummary.userSummary,
                        systemImage: "hammer",
                        tint: LuminaTheme.aqua
                    ) {
                        toolDetails(runSummary.toolResults)
                    }
                    disclosure(
                        id: "Raw Debug",
                        title: "Raw Debug",
                        subtitle: "状态、耗时和错误摘要",
                        systemImage: "curlybraces",
                        tint: .secondary
                    ) {
                        rawDebug(runSummary)
                    }
                }
                if !visibleAttachments.isEmpty {
                    disclosure(
                        id: "Attachments",
                        title: "Attachments",
                        subtitle: "\(visibleAttachments.count) 个附件",
                        systemImage: "paperclip",
                        tint: LuminaTheme.amber
                    ) {
                        AgentContentListView(content: visibleAttachments)
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top) {
            LuminaSectionHeader(
                title: isRunning ? "Lumina 正在回复" : "Lumina 回复",
                subtitle: "最终结果会整理成可读 Markdown"
            )
            Spacer()
            if isRunning {
                ProgressView()
                    .controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var fallbackFooter: some View {
        if modelReadiness.lastRunUsedFallback {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    LuminaStatusPill(
                        title: "Model",
                        value: modelReadiness.modelState == .ready ? "Fallback used" : modelReadiness.modelState.displayName,
                        systemImage: "cpu",
                        tint: LuminaTheme.amber
                    )
                    if modelReadiness.modelState == .ready && !isRunning {
                        Button(action: rerunWithModel) {
                            Label("用端侧模型重新运行", systemImage: "arrow.clockwise")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(LuminaTheme.deepInk)
                    }
                }
                Text(modelReadiness.modelMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func disclosure<Content: View>(
        id: String,
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isOpen = expandedSections.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                    if isOpen {
                        expandedSections.remove(id)
                    } else {
                        expandedSections.insert(id)
                    }
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(tint)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(0.13), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(LuminaTheme.ink)
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(11)
                .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

            if isOpen {
                content()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func toolDetails(_ toolResults: [LuminaToolResult]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(toolResults, id: \.callID) { result in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(result.toolName)
                            .font(.caption.monospaced().weight(.bold))
                        Spacer()
                        Text(result.status.rawValue)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(color(for: result.status))
                    }
                    Text(friendlySummary(for: result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let error = result.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(LuminaTheme.rose)
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }

    private func rawDebug(_ summary: LuminaAgentRunSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("status: \(summary.status.rawValue)")
            Text(String(format: "timing: total %.1fms / model %.1fms / tools %.1fms", summary.timing.totalMilliseconds, summary.timing.stepGenerationMilliseconds, summary.timing.toolExecutionMilliseconds))
            Text("summary: \(summary.planSummary)")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(summary.toolResults, id: \.callID) { result in
                Text("\(result.toolName): \(result.status.rawValue)\(result.errorMessage.map { " / \($0)" } ?? "")")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
    }

    private func friendlySummary(for result: LuminaToolResult) -> String {
        switch result.toolName {
        case "local.search":
            if case let .array(values)? = result.output["results"] {
                return values.isEmpty ? "没有找到匹配的本地记忆。" : "找到 \(values.count) 条本地记忆。"
            }
            return "本地检索已完成。"
        case "calendar.create":
            if let title = result.output["title"]?.stringValue {
                return "已创建日程：\(title)"
            }
            return "日程创建请求已完成。"
        case "calendar.search":
            if case let .array(values)? = result.output["events"] {
                return values.isEmpty ? "没有找到匹配的日程。" : "找到 \(values.count) 个日程。"
            }
            return "日程查询已完成。"
        case "reminder.create":
            if let title = result.output["title"]?.stringValue {
                return "已创建提醒：\(title)"
            }
            return "提醒事项创建请求已完成。"
        case "device.current_time":
            return result.output["iso8601"]?.stringValue ?? "已读取本机当前时间。"
        case "notification.schedule":
            return result.output["title"]?.stringValue.map { "已安排本地通知：\($0)" } ?? "本地通知已安排。"
        case "contacts.search":
            if case let .array(values)? = result.output["contacts"] {
                return values.isEmpty ? "没有找到匹配联系人。" : "找到 \(values.count) 个联系人。"
            }
            return "通讯录查询已完成。"
        case "location.current":
            return result.output["summary"]?.stringValue ?? "已读取当前位置。"
        case "clipboard.read":
            return result.output["summary"]?.stringValue ?? "已读取剪贴板。"
        case "file.save_note":
            return result.output["filename"]?.stringValue.map { "已保存文件：\($0)" } ?? "文件已保存。"
        case "url.open":
            return result.output["url"]?.stringValue.map { "已打开：\($0)" } ?? "打开请求已发送。"
        case "memory.ingest_text":
            return result.output["title"]?.stringValue.map { "已写入记忆：\($0)" } ?? "记忆已写入。"
        case "ledger.search":
            if case let .array(values)? = result.output["transactions"] {
                return values.isEmpty ? "没有找到匹配账目。" : "找到 \(values.count) 条账目。"
            }
            return "账目查询已完成。"
        default:
            return result.errorMessage ?? "工具调用已完成。"
        }
    }

    private var visibleAttachments: [LuminaAgentContentPart] {
        content.filter {
            switch $0 {
            case .markdown, .text:
                return false
            default:
                return true
            }
        }
    }

    private func color(for status: LuminaToolResultStatus) -> Color {
        switch status {
        case .succeeded:
            return LuminaTheme.mint
        case .failed:
            return LuminaTheme.rose
        case .cancelled, .denied:
            return LuminaTheme.amber
        }
    }
}
