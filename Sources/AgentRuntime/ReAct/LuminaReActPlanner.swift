import Foundation

public protocol LuminaReActPlanner: Sendable {
    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep
}
