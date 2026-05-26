import LuminaAgentClient
import Foundation

struct LuminaRunStreamObserver {
    private var startedAt: ContinuousClock.Instant?
    private var permissionTimingMark = 0
    private var confirmationStartedAt: ContinuousClock.Instant?
    private var toolStarts: [UUID: ContinuousClock.Instant] = [:]
    private var confirmationWaitMilliseconds = Double(0)
    private var observedToolExecutionMilliseconds = Double(0)

    mutating func start() {
        startedAt = ContinuousClock.now
        permissionTimingMark = LuminaPermissionTimingRecorder.shared.mark()
    }

    mutating func observe(_ event: LuminaAgentRunEvent) {
        switch event {
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
            observedToolExecutionMilliseconds: observedToolExecutionMilliseconds
        )
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
