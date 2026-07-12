import LuminaAgentRuntime
import Foundation

struct LuminaAgenticRLTrajectoryStep: Codable, Hashable {
    let type: String
    let content: String?
    let toolName: String?
    let parameters: [String: LuminaJSONValue]?
    let toolCalls: [LuminaToolCall]?
    let observationStatus: String?
    let elapsedMilliseconds: Double

    static func make(from step: LuminaReActStep) -> LuminaAgenticRLTrajectoryStep {
        switch step.kind {
        case .thought:
            return LuminaAgenticRLTrajectoryStep(type: "reasoning", content: step.thought, toolName: nil, parameters: nil, toolCalls: nil, observationStatus: nil, elapsedMilliseconds: step.elapsedMilliseconds)
        case .action:
            return LuminaAgenticRLTrajectoryStep(
                type: "tool_use",
                content: step.thought,
                toolName: step.action?.toolName,
                parameters: step.action?.arguments,
                toolCalls: nil,
                observationStatus: nil,
                elapsedMilliseconds: step.elapsedMilliseconds
            )
        case .multiAction:
            return LuminaAgenticRLTrajectoryStep(
                type: "multi_tool_use",
                content: step.thought,
                toolName: nil,
                parameters: nil,
                toolCalls: step.toolCalls,
                observationStatus: nil,
                elapsedMilliseconds: step.elapsedMilliseconds
            )
        case .observation:
            return LuminaAgenticRLTrajectoryStep(
                type: "observation",
                content: step.observation?.summary,
                toolName: step.observation?.toolName,
                parameters: nil,
                toolCalls: nil,
                observationStatus: step.observation?.status.rawValue,
                elapsedMilliseconds: step.elapsedMilliseconds
            )
        case .result:
            return LuminaAgenticRLTrajectoryStep(type: "result", content: step.resultMarkdown, toolName: nil, parameters: nil, toolCalls: nil, observationStatus: nil, elapsedMilliseconds: step.elapsedMilliseconds)
        }
    }
}
