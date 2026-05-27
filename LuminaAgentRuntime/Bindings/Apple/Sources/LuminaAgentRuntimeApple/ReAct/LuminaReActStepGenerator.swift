import Foundation

public protocol LuminaReActStepGenerator: Sendable {
    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep
}
