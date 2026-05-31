import LuminaAgentRuntime
import Foundation

struct LuminaRunStreamObserver {
    private var startedAt: ContinuousClock.Instant?
    private var permissionTimingMark = 0
    private var confirmationStartedAt: ContinuousClock.Instant?
    private var toolStarts: [UUID: ContinuousClock.Instant] = [:]
    private var confirmationWaitMilliseconds = Double(0)
    private var observedToolExecutionMilliseconds = Double(0)
    private var runtimeMetrics = LuminaBenchmarkRuntimeMetrics()

    mutating func start() {
        startedAt = ContinuousClock.now
        permissionTimingMark = LuminaPermissionTimingRecorder.shared.mark()
    }

    mutating func observe(_ event: LuminaAgentRunEvent) {
        switch event {
        case .stepGenerationStarted:
            runtimeMetrics.stepGenerationStartCount += 1
        case let .stepGenerationProgress(progress):
            runtimeMetrics.modelProgressEventCount += 1
            if progress.message.localizedCaseInsensitiveContains("retry") {
                runtimeMetrics.retryCount += 1
            }
        case .resultGenerated:
            runtimeMetrics.resultGeneratedCount += 1
        case .observationCreated:
            runtimeMetrics.observationCount += 1
        case let .hookAnnotated(key, value):
            runtimeMetrics.hookEventCount += 1
            runtimeMetrics.runtimeEventCount += key.hasPrefix("runtime") ? 1 : 0
            classifyRuntimeDiagnostic(key: key, value: value)
        case .confirmationRequired:
            confirmationStartedAt = ContinuousClock.now
        case .confirmationResolved:
            if let confirmationStartedAt {
                confirmationWaitMilliseconds += milliseconds(since: confirmationStartedAt)
                self.confirmationStartedAt = nil
            }
        case let .toolStarted(call):
            toolStarts[call.id] = ContinuousClock.now
        case let .toolFinished(result):
            if let start = toolStarts.removeValue(forKey: result.callID) {
                observedToolExecutionMilliseconds += milliseconds(since: start)
            }
            if result.status != .succeeded {
                runtimeMetrics.toolFailureCount += 1
                classifyDiagnosticText(result.errorMessage ?? result.output.compactModelTraceValue)
            }
        case let .finished(result):
            if result.status == .cancelled {
                runtimeMetrics.cancellationCount += 1
            }
            if result.status != .succeeded {
                classifyDiagnosticText(result.plan.summary)
            }
        default:
            break
        }
    }

    func finish(result: LuminaAgentRunResult?) -> LuminaObservedRunTimings {
        let wallClock = startedAt.map(milliseconds(since:)) ?? 0
        let modelGeneration = result?.timing.stepGenerationMilliseconds ?? 0
        let permissionWait = LuminaPermissionTimingRecorder.shared.milliseconds(after: permissionTimingMark)
        let measuredToolExecution = max(0, observedToolExecutionMilliseconds - permissionWait)
        let active = modelGeneration + measuredToolExecution
        return LuminaObservedRunTimings(
            wallClockMilliseconds: wallClock,
            activeRuntimeMilliseconds: active,
            confirmationWaitMilliseconds: confirmationWaitMilliseconds,
            systemPermissionWaitMilliseconds: permissionWait,
            observedToolExecutionMilliseconds: observedToolExecutionMilliseconds,
            runtimeMetrics: runtimeMetrics
        )
    }

    private mutating func classifyRuntimeDiagnostic(key: String, value: LuminaJSONValue) {
        classifyDiagnosticText(key)
        classifyDiagnosticText(Self.string(for: value))
    }

    private mutating func classifyDiagnosticText(_ text: String) {
        let lowered = text.lowercased()
        if lowered.contains("invalid react") ||
            lowered.contains("parser") ||
            lowered.contains("did not produce valid") ||
            lowered.contains("normalization") ||
            lowered.contains("normalize") {
            runtimeMetrics.normalizationFailureCount += 1
        }
        if lowered.contains("invalid schema") ||
            lowered.contains("missing required") ||
            lowered.contains("schema validation") ||
            lowered.contains("parameter") && lowered.contains("required") {
            runtimeMetrics.schemaValidationFailureCount += 1
        }
        if lowered.contains("observation") &&
            (lowered.contains("model") || lowered.contains("never output") || lowered.contains("runtime-only") || lowered.contains("not allowed")) {
            runtimeMetrics.modelOwnedObservationRejectCount += 1
        }
        if lowered.contains("unknown tool") ||
            lowered.contains("tool is not registered") ||
            lowered.contains("not registered") {
            runtimeMetrics.unknownToolRejectCount += 1
        }
        if lowered.contains("fallback") || lowered.contains("回落") {
            runtimeMetrics.fallbackCount += 1
        }
        if lowered.contains("retry") || lowered.contains("重试") {
            runtimeMetrics.retryCount += 1
        }
    }

    private static func string(for value: LuminaJSONValue) -> String {
        if case let .string(string) = value {
            return string
        }
        return value.compactModelTraceValue
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
