import Foundation

public struct LuminaAgentRuntimeConfiguration: Codable, Hashable, Sendable {
    public var maximumToolCalls: Int
    public var maximumReActIterations: Int
    public var maximumObservationCharacters: Int
    public var stopOnToolFailure: Bool
    public var rollbackFailedSideEffects: Bool
    public var emitVerboseEvents: Bool
    public var contextWindowCharacterBudget: Int
    public var autoCompactThreshold: Double
    public var preservedStepsAfterCompaction: Int

    public init(
        maximumToolCalls: Int = 8,
        maximumReActIterations: Int = 12,
        maximumObservationCharacters: Int = 1_500,
        stopOnToolFailure: Bool = false,
        rollbackFailedSideEffects: Bool = true,
        emitVerboseEvents: Bool = true,
        contextWindowCharacterBudget: Int = 24_000,
        autoCompactThreshold: Double = 0.82,
        preservedStepsAfterCompaction: Int = 6
    ) {
        self.maximumToolCalls = maximumToolCalls
        self.maximumReActIterations = maximumReActIterations
        self.maximumObservationCharacters = maximumObservationCharacters
        self.stopOnToolFailure = stopOnToolFailure
        self.rollbackFailedSideEffects = rollbackFailedSideEffects
        self.emitVerboseEvents = emitVerboseEvents
        self.contextWindowCharacterBudget = contextWindowCharacterBudget
        self.autoCompactThreshold = autoCompactThreshold
        self.preservedStepsAfterCompaction = preservedStepsAfterCompaction
    }
}
