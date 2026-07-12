@testable import LuminaAgentRuntimeApple

let luminaTestRuntimeConfiguration = LuminaAgentRuntimeConfiguration(
    maximumToolCalls: 8,
    maximumReActIterations: 12,
    maximumObservationCharacters: 1_500,
    contextWindowTokens: 12_000,
    maxOutputTokens: 4_096,
    reservedOutputTokens: 256,
    toolResultTokenBudget: 1_024,
    compactThresholdTokens: 1_800,
    maximumCompactFailures: 3,
    maximumConsecutiveReasoningSteps: 3,
    maximumConsecutiveReplayObservations: 2,
    stopOnToolFailure: false,
    rollbackFailedSideEffects: true,
    emitVerboseEvents: true,
    preservedStepsAfterCompaction: 6
)

func luminaTestRuntimeConfiguration(
    maximumToolCalls: Int = 8,
    maximumReActIterations: Int = 12,
    maximumObservationCharacters: Int = 1_500,
    contextWindowTokens: Int = 12_000,
    maxOutputTokens: Int = 4_096,
    reservedOutputTokens: Int = 256,
    toolResultTokenBudget: Int = 1_024,
    compactThresholdTokens: Int = 1_800,
    maximumCompactFailures: Int = 3,
    maximumConsecutiveReasoningSteps: Int = 3,
    maximumConsecutiveReplayObservations: Int = 2,
    stopOnToolFailure: Bool = false,
    rollbackFailedSideEffects: Bool = true,
    emitVerboseEvents: Bool = true,
    preservedStepsAfterCompaction: Int = 6,
    yoloMode: Bool = false,
    multiToolUseEnabled: Bool = true,
    continueReadOnlyMultiToolFailures: Bool = true,
    ignoreInternalToolCalls: Bool = false
) -> LuminaAgentRuntimeConfiguration {
    LuminaAgentRuntimeConfiguration(
        maximumToolCalls: maximumToolCalls,
        maximumReActIterations: maximumReActIterations,
        maximumObservationCharacters: maximumObservationCharacters,
        contextWindowTokens: contextWindowTokens,
        maxOutputTokens: maxOutputTokens,
        reservedOutputTokens: reservedOutputTokens,
        toolResultTokenBudget: toolResultTokenBudget,
        compactThresholdTokens: compactThresholdTokens,
        maximumCompactFailures: maximumCompactFailures,
        maximumConsecutiveReasoningSteps: maximumConsecutiveReasoningSteps,
        maximumConsecutiveReplayObservations: maximumConsecutiveReplayObservations,
        stopOnToolFailure: stopOnToolFailure,
        rollbackFailedSideEffects: rollbackFailedSideEffects,
        emitVerboseEvents: emitVerboseEvents,
        preservedStepsAfterCompaction: preservedStepsAfterCompaction,
        yoloMode: yoloMode,
        multiToolUseEnabled: multiToolUseEnabled,
        continueReadOnlyMultiToolFailures: continueReadOnlyMultiToolFailures,
        ignoreInternalToolCalls: ignoreInternalToolCalls
    )
}

let luminaKernelRuntimeConfigurationJSON = """
{"maxIterations":12,"maxToolCalls":8,"contextWindowTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false}
"""

func luminaKernelRuntimeConfigurationJSON(maxIterations: Int, yoloMode: Bool = false) -> String {
    """
    {"maxIterations":\(maxIterations),"maxToolCalls":8,"contextWindowTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":2,"stopOnToolFailure":false,"yoloMode":\(yoloMode)}
    """
}
