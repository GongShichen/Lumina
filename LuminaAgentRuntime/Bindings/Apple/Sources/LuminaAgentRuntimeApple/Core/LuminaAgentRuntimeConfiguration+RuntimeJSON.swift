import Foundation

extension LuminaAgentRuntimeConfiguration {
    var runtimeJSON: String {
        """
        {"maxIterations":\(maximumReActIterations),"maxToolCalls":\(maximumToolCalls),"contextWindowTokens":\(contextWindowTokens),"maxContextTokens":\(contextWindowTokens),"maxOutputTokens":\(maxOutputTokens),"reservedOutputTokens":\(reservedOutputTokens),"autoCompactBufferTokens":\(autoCompactBufferTokens),"warningBufferTokens":\(warningBufferTokens),"maxObservationCharacters":\(maximumObservationCharacters),"toolResultTokenBudget":\(toolResultTokenBudget),"compactThresholdTokens":\(compactThresholdTokens),"maxCompactFailures":\(maximumCompactFailures),"maxReasoningSteps":\(maximumConsecutiveReasoningSteps),"maxReplayObservations":\(maximumConsecutiveReplayObservations),"stopOnToolFailure":\(stopOnToolFailure),"yoloMode":\(yoloMode),"multiToolUseEnabled":\(multiToolUseEnabled),"continueReadOnlyMultiToolFailures":\(continueReadOnlyMultiToolFailures),"ignoreInternalToolCalls":\(ignoreInternalToolCalls),"toolSchemaProfile":"\(toolSchemaDisclosureProfile.rawValue)","toolLoadingMode":"\(toolLoadingMode)","toolLoadingThresholdRatio":\(toolLoadingThresholdRatio),"checkpointPolicy":"\(checkpointPolicy.rawValue)"}
        """
    }
}
