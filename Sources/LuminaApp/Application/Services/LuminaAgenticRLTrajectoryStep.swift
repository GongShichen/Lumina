import AgentRuntime
import Foundation

struct LuminaAgenticRLTrajectoryStep: Codable, Hashable {
    let type: String
    let content: String?
    let toolName: String?
    let parameters: [String: LuminaJSONValue]?
    let observationStatus: String?
    let elapsedMilliseconds: Double

    static func make(from step: LuminaReActStep) -> LuminaAgenticRLTrajectoryStep {
        switch step.kind {
        case .thought:
            return LuminaAgenticRLTrajectoryStep(type: "thought", content: step.thought, toolName: nil, parameters: nil, observationStatus: nil, elapsedMilliseconds: step.elapsedMilliseconds)
        case .action:
            return LuminaAgenticRLTrajectoryStep(
                type: "action",
                content: step.thought,
                toolName: step.action?.toolName,
                parameters: step.action?.arguments,
                observationStatus: nil,
                elapsedMilliseconds: step.elapsedMilliseconds
            )
        case .observation:
            return LuminaAgenticRLTrajectoryStep(
                type: "observation",
                content: step.observation?.summary,
                toolName: step.observation?.toolName,
                parameters: nil,
                observationStatus: step.observation?.status.rawValue,
                elapsedMilliseconds: step.elapsedMilliseconds
            )
        case .final:
            return LuminaAgenticRLTrajectoryStep(type: "final", content: step.finalMarkdown, toolName: nil, parameters: nil, observationStatus: nil, elapsedMilliseconds: step.elapsedMilliseconds)
        }
    }
}
