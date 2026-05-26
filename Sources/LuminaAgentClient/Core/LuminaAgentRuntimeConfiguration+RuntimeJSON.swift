import Foundation

extension LuminaAgentRuntimeConfiguration {
    var runtimeJSON: String {
        """
        {"maximumReActIterations":\(maximumReActIterations),"maximumToolCalls":\(maximumToolCalls),"maximumObservationCharacters":\(maximumObservationCharacters),"maximumContextTokens":\(max(1_024, contextWindowCharacterBudget / 4)),"stopOnToolFailure":\(stopOnToolFailure)}
        """
    }
}
