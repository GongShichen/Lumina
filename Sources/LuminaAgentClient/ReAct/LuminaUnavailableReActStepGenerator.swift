import Foundation

public struct LuminaUnavailableReActStepGenerator: LuminaReActStepGenerator {
    public init() {}

    public func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        throw LuminaNoAvailableReActStepGeneratorError()
    }
}
