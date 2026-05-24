import Foundation
import LuminaModelRuntime

struct LuminaAgenticRLTrajectoryRecord: Identifiable, Codable, Hashable {
    struct TaskPayload: Codable, Hashable {
        let id: String
        let instruction: String
        let category: String
        let expectedTools: [String]
        let difficulty: String
        let cleanupPrefixes: [String]
    }

    struct EnvironmentPayload: Codable, Hashable {
        let app: String
        let runtime: String
        let schemaVersion: String
        let localOnly: Bool
    }

    struct MessagePayload: Codable, Hashable {
        let role: String
        let content: String
    }

    let id: String
    let schemaVersion: String
    let createdAt: Date
    let task: TaskPayload
    let environment: EnvironmentPayload
    let messages: [MessagePayload]
    let steps: [LuminaAgenticRLTrajectoryStep]
    let actualTools: [String]
    let outcome: LuminaAgenticRLOutcome
    let modelMetrics: [LuminaModelInferenceMetrics]
}
