import Foundation

public struct LuminaAgentRuntimeConfiguration: Codable, Hashable, Sendable {
    public var maximumToolCalls: Int
    public var maximumReActIterations: Int
    public var maximumObservationCharacters: Int
    public var contextWindowTokens: Int
    public var maxOutputTokens: Int
    public var reservedOutputTokens: Int
    public var autoCompactBufferTokens: Int
    public var warningBufferTokens: Int
    public var toolResultTokenBudget: Int
    public var compactThresholdTokens: Int
    public var maximumCompactFailures: Int
    public var maximumConsecutiveReasoningSteps: Int
    public var maximumConsecutiveReplayObservations: Int
    public var stopOnToolFailure: Bool
    public var rollbackFailedSideEffects: Bool
    public var emitVerboseEvents: Bool
    public var preservedStepsAfterCompaction: Int
    public var toolSchemaDisclosureProfile: LuminaToolSchemaDisclosureProfile
    public var checkpointPolicy: LuminaRuntimeCheckpointPolicy

    public init(
        maximumToolCalls: Int,
        maximumReActIterations: Int,
        maximumObservationCharacters: Int,
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        reservedOutputTokens: Int,
        autoCompactBufferTokens: Int? = nil,
        warningBufferTokens: Int? = nil,
        toolResultTokenBudget: Int,
        compactThresholdTokens: Int,
        maximumCompactFailures: Int,
        maximumConsecutiveReasoningSteps: Int,
        maximumConsecutiveReplayObservations: Int,
        stopOnToolFailure: Bool,
        rollbackFailedSideEffects: Bool,
        emitVerboseEvents: Bool,
        preservedStepsAfterCompaction: Int,
        toolSchemaDisclosureProfile: LuminaToolSchemaDisclosureProfile = .compact,
        checkpointPolicy: LuminaRuntimeCheckpointPolicy = .none
    ) {
        self.maximumToolCalls = maximumToolCalls
        self.maximumReActIterations = maximumReActIterations
        self.maximumObservationCharacters = maximumObservationCharacters
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = maxOutputTokens
        self.reservedOutputTokens = reservedOutputTokens
        self.autoCompactBufferTokens = autoCompactBufferTokens ?? compactThresholdTokens
        self.warningBufferTokens = warningBufferTokens ?? max(autoCompactBufferTokens ?? compactThresholdTokens, compactThresholdTokens)
        self.toolResultTokenBudget = toolResultTokenBudget
        self.compactThresholdTokens = compactThresholdTokens
        self.maximumCompactFailures = maximumCompactFailures
        self.maximumConsecutiveReasoningSteps = maximumConsecutiveReasoningSteps
        self.maximumConsecutiveReplayObservations = maximumConsecutiveReplayObservations
        self.stopOnToolFailure = stopOnToolFailure
        self.rollbackFailedSideEffects = rollbackFailedSideEffects
        self.emitVerboseEvents = emitVerboseEvents
        self.preservedStepsAfterCompaction = preservedStepsAfterCompaction
        self.toolSchemaDisclosureProfile = toolSchemaDisclosureProfile
        self.checkpointPolicy = checkpointPolicy
    }
}
