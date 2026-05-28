import Foundation

extension LuminaAgentRuntimeConfiguration {
    var runtimeJSON: String {
        """
        {"maxIterations":\(maximumReActIterations),"maxToolCalls":\(maximumToolCalls),"contextWindowTokens":\(contextWindowTokens),"maxOutputTokens":\(maxOutputTokens),"reservedOutputTokens":\(reservedOutputTokens),"maxObservationCharacters":\(maximumObservationCharacters),"toolResultTokenBudget":\(toolResultTokenBudget),"compactThresholdTokens":\(compactThresholdTokens),"maxCompactFailures":\(maximumCompactFailures),"maxReasoningSteps":\(maximumConsecutiveReasoningSteps),"maxReplayObservations":\(maximumConsecutiveReplayObservations),"stopOnToolFailure":\(stopOnToolFailure)}
        """
    }
}
