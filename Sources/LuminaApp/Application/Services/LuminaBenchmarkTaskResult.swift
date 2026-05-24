import Foundation
import LuminaModelRuntime

struct LuminaBenchmarkTaskResult: Identifiable, Codable, Hashable {
    let id: String
    let taskID: String
    let text: String
    let expectedTools: [String]
    let actualTools: [String]
    let status: String
    let exactMatch: Bool
    let recall: Double
    let precision: Double
    let f1: Double
    let totalMilliseconds: Double
    let activeRuntimeMilliseconds: Double
    let wallClockMilliseconds: Double
    let confirmationWaitMilliseconds: Double
    let planningMilliseconds: Double
    let toolMilliseconds: Double
    let modelMetrics: [LuminaModelInferenceMetrics]
    let failureSummary: String?

    init(
        task: LuminaBenchmarkTask,
        actualTools: [String],
        status: String,
        totalMilliseconds: Double,
        observedTimings: LuminaObservedRunTimings,
        planningMilliseconds: Double,
        toolMilliseconds: Double,
        modelMetrics: [LuminaModelInferenceMetrics],
        failureSummary: String?
    ) {
        self.id = task.id
        self.taskID = task.id
        self.text = task.text
        self.expectedTools = task.expectedTools
        self.actualTools = actualTools
        self.status = status
        self.exactMatch = Set(task.expectedTools) == Set(actualTools)
        let expected = Set(task.expectedTools)
        let actual = Set(actualTools)
        let truePositive = Double(expected.intersection(actual).count)
        let falsePositive = Double(actual.subtracting(expected).count)
        let falseNegative = Double(expected.subtracting(actual).count)
        self.precision = truePositive + falsePositive == 0 ? 0 : truePositive / (truePositive + falsePositive)
        self.recall = truePositive + falseNegative == 0 ? 0 : truePositive / (truePositive + falseNegative)
        self.f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        self.totalMilliseconds = totalMilliseconds
        self.activeRuntimeMilliseconds = observedTimings.activeRuntimeMilliseconds
        self.wallClockMilliseconds = observedTimings.wallClockMilliseconds
        self.confirmationWaitMilliseconds = observedTimings.confirmationWaitMilliseconds
        self.planningMilliseconds = planningMilliseconds
        self.toolMilliseconds = toolMilliseconds
        self.modelMetrics = modelMetrics
        self.failureSummary = failureSummary
    }
}
