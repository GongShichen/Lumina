import Foundation

public struct AgentRuntimeConfiguration: Codable, Hashable, Sendable {
    public var maximumToolCalls: Int
    public var maximumReActIterations: Int
    public var maximumObservationCharacters: Int
    public var stopOnToolFailure: Bool
    public var rollbackFailedSideEffects: Bool
    public var emitVerboseEvents: Bool

    public init(
        maximumToolCalls: Int = 8,
        maximumReActIterations: Int = 12,
        maximumObservationCharacters: Int = 1_500,
        stopOnToolFailure: Bool = false,
        rollbackFailedSideEffects: Bool = true,
        emitVerboseEvents: Bool = true
    ) {
        self.maximumToolCalls = maximumToolCalls
        self.maximumReActIterations = maximumReActIterations
        self.maximumObservationCharacters = maximumObservationCharacters
        self.stopOnToolFailure = stopOnToolFailure
        self.rollbackFailedSideEffects = rollbackFailedSideEffects
        self.emitVerboseEvents = emitVerboseEvents
    }
}

public struct RuntimeTiming: Codable, Hashable, Sendable {
    public var planningMilliseconds: Double
    public var toolExecutionMilliseconds: Double
    public var totalMilliseconds: Double

    public init(
        planningMilliseconds: Double = 0,
        toolExecutionMilliseconds: Double = 0,
        totalMilliseconds: Double = 0
    ) {
        self.planningMilliseconds = planningMilliseconds
        self.toolExecutionMilliseconds = toolExecutionMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

public enum RuntimeClock {
    public static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
    }
}
