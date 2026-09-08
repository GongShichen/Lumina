import LuminaAgentRuntime
import Foundation

struct LuminaAgentRunSummary: Equatable, Sendable {
    var status: LuminaAgentRunStatus
    var timing: LuminaRuntimeTiming
    var toolResults: [LuminaToolResult]
    var planSummary: String

    init(result: LuminaAgentRunResult) {
        self.status = result.status
        self.timing = result.timing
        self.toolResults = result.toolResults
        self.planSummary = result.plan.summary
    }

    var userSummary: String {
        if toolResults.isEmpty {
            return status == .succeeded ? "没有需要执行的工具。" : "本次执行未完成。"
        }
        let succeeded = toolResults.filter { $0.status == .succeeded }.count
        if status == .succeeded {
            return "任务已完成，\(succeeded) 次工具调用成功。" + (succeeded < toolResults.count ? "纠正前的失败尝试保留在下方记录中。" : "")
        }
        return "\(succeeded) 次工具调用成功，\(toolResults.count - succeeded) 次尝试未完成。"
    }

    var sourceCount: Int {
        toolResults.reduce(0) { count, result in
            if case let .array(values)? = result.output["results"] {
                return count + values.count
            }
            if case let .array(values)? = result.output["events"] {
                return count + values.count
            }
            return count
        }
    }
}
