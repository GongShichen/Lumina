import AgentRuntime
import Foundation

struct AgentRunTimelineItem: Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String?
    var systemImage: String
    var status: TimelineStatus

    enum TimelineStatus: String, Hashable {
        case active
        case success
        case warning
        case failure
        case info
    }
}

enum AgentRunEventPresenter {
    static func item(for event: AgentRunEvent) -> AgentRunTimelineItem? {
        switch event {
        case .planningStarted:
            return AgentRunTimelineItem(title: "开始规划", detail: nil, systemImage: "brain", status: .active)
        case let .planCreated(plan):
            return AgentRunTimelineItem(title: "计划已生成", detail: plan.summary, systemImage: "list.bullet.clipboard", status: .success)
        case let .thoughtGenerated(step):
            return AgentRunTimelineItem(title: "ReAct 思考", detail: step.thought, systemImage: "bubble.left.and.text.bubble.right", status: .info)
        case let .actionProposed(call):
            return AgentRunTimelineItem(title: "ReAct 动作：\(call.toolName)", detail: nil, systemImage: "arrowshape.turn.up.right", status: .active)
        case let .observationCreated(observation):
            return AgentRunTimelineItem(title: "ReAct 观察：\(observation.toolName)", detail: observation.summary, systemImage: "eye", status: status(for: observation.status))
        case let .finalGenerated(markdown):
            return AgentRunTimelineItem(title: "ReAct 最终回答", detail: markdown, systemImage: "text.badge.checkmark", status: .success)
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
                detail: result.errorMessage ?? result.output.keys.sorted().joined(separator: ", "),
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
                detail: String(format: "总 %.1fms / 规划 %.1fms / 工具 %.1fms", result.timing.totalMilliseconds, result.timing.planningMilliseconds, result.timing.toolExecutionMilliseconds),
                systemImage: result.status == .succeeded ? "checkmark.seal" : "exclamationmark.triangle",
                status: result.status == .succeeded ? .success : .warning
            )
        }
    }

    private static func icon(for status: ToolResultStatus) -> String {
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

    private static func status(for status: ToolResultStatus) -> AgentRunTimelineItem.TimelineStatus {
        switch status {
        case .succeeded:
            return .success
        case .failed:
            return .failure
        case .cancelled, .denied:
            return .warning
        }
    }
}
