import Foundation
import LuminaModelRuntime

struct LuminaBenchmarkTaskResult: Identifiable, Codable, Hashable {
    let id: String
    let taskID: String
    let text: String
    let expectedTools: [String]
    let toolAttempts: [String]
    let actualTools: [String]
    let toolReplays: [String]
    let toolAttemptCount: Int
    let toolExecutionCount: Int
    let toolReplayCount: Int
    let status: String
    let exactMatch: Bool
    let recall: Double
    let precision: Double
    let f1: Double
    let totalMilliseconds: Double
    let activeRuntimeMilliseconds: Double
    let wallClockMilliseconds: Double
    let confirmationWaitMilliseconds: Double
    let systemPermissionWaitMilliseconds: Double
    let stepGenerationMilliseconds: Double
    let toolMilliseconds: Double
    let modelMetrics: [LuminaModelInferenceMetrics]
    let failureSummary: String?

    init(
        task: LuminaBenchmarkTask,
        toolAttempts: [String],
        actualTools: [String],
        toolReplays: [String],
        status: String,
        totalMilliseconds: Double,
        observedTimings: LuminaObservedRunTimings,
        stepGenerationMilliseconds: Double,
        toolMilliseconds: Double,
        modelMetrics: [LuminaModelInferenceMetrics],
        failureSummary: String?
    ) {
        self.id = task.id
        self.taskID = task.id
        self.text = task.text
        self.expectedTools = task.expectedTools
        self.toolAttempts = toolAttempts
        self.actualTools = actualTools
        self.toolReplays = toolReplays
        self.toolAttemptCount = toolAttempts.count
        self.toolExecutionCount = actualTools.count
        self.toolReplayCount = toolReplays.count
        let expected = Set(task.expectedTools)
        let actual = Set(actualTools)
        self.exactMatch = expected == actual
        let truePositive = Double(expected.intersection(actual).count)
        let falsePositive = Double(actual.subtracting(expected).count)
        let falseNegative = Double(expected.subtracting(actual).count)
        self.precision = truePositive + falsePositive == 0 ? 0 : truePositive / (truePositive + falsePositive)
        self.recall = truePositive + falseNegative == 0 ? 0 : truePositive / (truePositive + falseNegative)
        self.f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        self.status = status == "succeeded" && (expected.isEmpty || exactMatch) ? "succeeded" : status == "cancelled" ? "cancelled" : "failed"
        self.totalMilliseconds = totalMilliseconds
        self.activeRuntimeMilliseconds = observedTimings.activeRuntimeMilliseconds
        self.wallClockMilliseconds = observedTimings.wallClockMilliseconds
        self.confirmationWaitMilliseconds = observedTimings.confirmationWaitMilliseconds
        self.systemPermissionWaitMilliseconds = observedTimings.systemPermissionWaitMilliseconds
        self.stepGenerationMilliseconds = stepGenerationMilliseconds
        self.toolMilliseconds = toolMilliseconds
        self.modelMetrics = modelMetrics
        self.failureSummary = failureSummary
    }
}
