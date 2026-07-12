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
    let successfulTools: [String]
    let missingTools: [String]
    let unexpectedTools: [String]
    let failedTools: [String]
    let toolAttemptCount: Int
    let toolExecutionCount: Int
    let toolReplayCount: Int
    let failedToolCount: Int
    let status: String
    let passAt1: Bool
    let outcomePassed: Bool
    let outcomeFailures: [String]
    let strictToolPassed: Bool
    let orderedToolMatch: Bool
    let runtimeStatus: String
    let terminationReason: String?
    let toolExecutedAt1: Bool
    let exactMatch: Bool
    let semanticPassed: Bool
    let semanticFailures: [String]
    let toolDiagnosticsSummary: String?
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
    let runtimeMetrics: LuminaBenchmarkRuntimeMetrics
    let failureSummary: String?

    init(
        task: LuminaBenchmarkTask,
        toolAttempts: [String],
        actualTools: [String],
        toolReplays: [String],
        successfulTools: [String],
        failedTools: [String],
        outcomeFailures: [String],
        runtimeStatus: String,
        terminationReason: String?,
        semanticFailures: [String],
        status: String,
        totalMilliseconds: Double,
        observedTimings: LuminaObservedRunTimings,
        stepGenerationMilliseconds: Double,
        toolMilliseconds: Double,
        modelMetrics: [LuminaModelInferenceMetrics],
        runtimeMetrics: LuminaBenchmarkRuntimeMetrics,
        failureSummary: String?
    ) {
        self.id = task.id
        self.taskID = task.id
        self.text = task.text
        self.expectedTools = task.expectedTools
        self.toolAttempts = toolAttempts
        self.actualTools = actualTools
        self.toolReplays = toolReplays
        self.successfulTools = successfulTools
        self.failedTools = failedTools
        self.toolAttemptCount = toolAttempts.count
        self.toolExecutionCount = actualTools.count
        self.toolReplayCount = toolReplays.count
        self.failedToolCount = failedTools.count
        let expected = Set(task.expectedTools)
        let actual = Set(successfulTools)
        let allExecuted = Set(actualTools)
        self.missingTools = expected.subtracting(actual).sorted()
        self.unexpectedTools = allExecuted.subtracting(expected).sorted()
        self.orderedToolMatch = Self.isOrderedSubsequence(task.expectedTools, of: successfulTools)
        self.exactMatch = successfulTools == task.expectedTools && actualTools == task.expectedTools && failedTools.isEmpty && toolReplays.isEmpty
        self.semanticFailures = semanticFailures
        self.outcomeFailures = outcomeFailures
        self.runtimeStatus = runtimeStatus
        self.terminationReason = terminationReason
        self.outcomePassed = outcomeFailures.isEmpty
        self.semanticPassed = self.outcomePassed
        let truePositive = Double(expected.intersection(actual).count)
        let falsePositive = Double(allExecuted.subtracting(expected).count)
        let falseNegative = Double(expected.subtracting(actual).count)
        self.precision = truePositive + falsePositive == 0 ? 0 : truePositive / (truePositive + falsePositive)
        self.recall = truePositive + falseNegative == 0 ? 0 : truePositive / (truePositive + falseNegative)
        self.f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        self.strictToolPassed = self.outcomePassed && orderedToolMatch && self.unexpectedTools.isEmpty && failedTools.isEmpty && toolReplays.isEmpty
        self.passAt1 = self.outcomePassed
        self.toolExecutedAt1 = !task.expectedTools.isEmpty && orderedToolMatch
        self.status = self.outcomePassed ? "succeeded" : status == "cancelled" ? "cancelled" : "failed"
        let diagnostics = [
            self.missingTools.isEmpty ? nil : "missing=\(self.missingTools.joined(separator: ","))",
            self.unexpectedTools.isEmpty ? nil : "unexpected=\(self.unexpectedTools.joined(separator: ","))",
            failedTools.isEmpty ? nil : "failed=\(failedTools.joined(separator: ","))",
            toolReplays.isEmpty ? nil : "replayed=\(toolReplays.joined(separator: ","))"
        ].compactMap { $0 }
        self.toolDiagnosticsSummary = diagnostics.isEmpty ? nil : diagnostics.joined(separator: "; ")
        self.totalMilliseconds = totalMilliseconds
        self.activeRuntimeMilliseconds = observedTimings.activeRuntimeMilliseconds
        self.wallClockMilliseconds = observedTimings.wallClockMilliseconds
        self.confirmationWaitMilliseconds = observedTimings.confirmationWaitMilliseconds
        self.systemPermissionWaitMilliseconds = observedTimings.systemPermissionWaitMilliseconds
        self.stepGenerationMilliseconds = stepGenerationMilliseconds
        self.toolMilliseconds = toolMilliseconds
        self.modelMetrics = modelMetrics
        self.runtimeMetrics = runtimeMetrics
        self.failureSummary = failureSummary
    }

    private static func isOrderedSubsequence(_ expected: [String], of actual: [String]) -> Bool {
        guard !expected.isEmpty else { return true }
        var expectedIndex = 0
        for tool in actual where expectedIndex < expected.count {
            if tool == expected[expectedIndex] {
                expectedIndex += 1
            }
        }
        return expectedIndex == expected.count
    }
}
