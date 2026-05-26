import AgentRuntime
import Foundation

enum AgentRunEventPresenter {
    static func displaySummary(_ summary: String) -> String {
        if summary.localizedCaseInsensitiveContains("stepGenerator unavailable") {
            return "端侧模型 model 当前不可用。"
        }
        return summary
    }

    static func item(for event: LuminaAgentRunEvent) -> AgentRunTimelineItem? {
        switch event {
        case .stepGenerationStarted:
            return AgentRunTimelineItem(title: "开始 ReAct", detail: nil, systemImage: "brain", status: .active)
        case let .stepGenerationProgress(progress):
            let promptText = progress.promptTokens.map { "，prompt \($0) tokens" } ?? ""
            let sampledText = progress.outputTokens == 0 ? progress.sampledTokens.map { "，已采样 \($0) tokens" } ?? "" : ""
            let outputText = progress.outputTokens > 0 ? "，已输出 \(progress.outputTokens) tokens" : sampledText
            return AgentRunTimelineItem(
                coalescingKey: "step-generation-progress-\(progress.iteration)",
                title: "模型生成中",
                detail: String(format: "第 %d 轮 ReAct，已运行 %.1fs%@%@", progress.iteration + 1, progress.elapsedMilliseconds / 1_000, promptText, outputText),
                systemImage: "waveform.path.ecg",
                status: .active
            )
        case let .thoughtGenerated(step):
            return AgentRunTimelineItem(title: "ReAct 思考", detail: step.thought, systemImage: "bubble.left.and.text.bubble.right", status: .info)
        case let .actionProposed(call):
            return AgentRunTimelineItem(title: "ReAct 动作：\(call.toolName)", detail: nil, systemImage: "arrowshape.turn.up.right", status: .active)
        case let .observationCreated(observation):
            return AgentRunTimelineItem(title: "观察结果：\(observation.toolName)", detail: observation.summary, systemImage: "eye", status: status(for: observation.status))
        case .finalGenerated:
            return nil
        case let .hookAnnotated(key, value):
            return AgentRunTimelineItem(
                title: "运行标注：\(key)",
                detail: value.stringValue ?? String(describing: value),
                systemImage: "tag",
                status: .info
            )
        case let .contextUpdated(context):
            return AgentRunTimelineItem(
                title: "上下文已更新",
                detail: "\(context.sections.count) 个上下文片段",
                systemImage: "rectangle.stack.badge.plus",
                status: .info
            )
        case let .permissionChecked(call, decision):
            return AgentRunTimelineItem(
                title: "权限检查：\(call.toolName)",
                detail: String(describing: decision),
                systemImage: "lock.shield",
                status: .info
            )
        case let .confirmationRequired(call):
            return AgentRunTimelineItem(title: "等待确认：\(call.toolName)", detail: nil, systemImage: "person.crop.circle.badge.questionmark", status: .warning)
        case let .confirmationResolved(call, accepted):
            return AgentRunTimelineItem(
                title: accepted ? "已确认：\(call.toolName)" : "已取消：\(call.toolName)",
                detail: nil,
                systemImage: accepted ? "checkmark.circle" : "xmark.circle",
                status: accepted ? .success : .warning
            )
        case let .toolStarted(call):
            return AgentRunTimelineItem(title: "工具运行中：\(call.toolName)", detail: nil, systemImage: "hammer", status: .active)
        case let .toolFinished(result):
            return AgentRunTimelineItem(
                title: "工具完成：\(result.toolName)",
                detail: result.errorMessage ?? displayToolResult(result),
                systemImage: icon(for: result.status),
                status: status(for: result.status)
            )
        case let .rollbackStarted(call):
            return AgentRunTimelineItem(title: "开始回滚：\(call.toolName)", detail: nil, systemImage: "arrow.uturn.backward", status: .warning)
        case let .rollbackFinished(call, succeeded):
            return AgentRunTimelineItem(
                title: succeeded ? "回滚完成：\(call.toolName)" : "回滚失败：\(call.toolName)",
                detail: nil,
                systemImage: succeeded ? "checkmark.arrow.trianglehead.counterclockwise" : "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90",
                status: succeeded ? .success : .failure
            )
        case let .finished(result):
            return AgentRunTimelineItem(
                title: "运行结束：\(result.status.rawValue)",
                detail: String(format: "总 %.1fms / 模型 %.1fms / 工具 %.1fms", result.timing.totalMilliseconds, result.timing.stepGenerationMilliseconds, result.timing.toolExecutionMilliseconds),
                systemImage: result.status == .succeeded ? "checkmark.seal" : "exclamationmark.triangle",
                status: result.status == .succeeded ? .success : .warning
            )
        }
    }

    private static func icon(for status: LuminaToolResultStatus) -> String {
        switch status {
        case .succeeded:
            return "checkmark.circle"
        case .failed:
            return "xmark.octagon"
        case .cancelled:
            return "minus.circle"
        case .denied:
            return "hand.raised"
        }
    }

    private static func status(for status: LuminaToolResultStatus) -> AgentRunTimelineItem.TimelineStatus {
        switch status {
        case .succeeded:
            return .success
        case .failed:
            return .failure
        case .cancelled, .denied:
            return .warning
        }
    }

    private static func displayToolResult(_ result: LuminaToolResult) -> String {
        switch result.toolName {
        case "local.search":
            if case let .array(values)? = result.output["results"] {
                return values.isEmpty ? "本地记忆没有匹配结果。" : "找到 \(values.count) 条本地记忆。"
            }
            return "本地检索完成。"
        case "calendar.create":
            let title = result.output.string("title") ?? "日程"
            return "已创建日程：\(title)。"
        case "reminder.create":
            return "提醒事项已创建。"
        default:
            return result.output.keys.sorted().joined(separator: ", ")
        }
    }
}
