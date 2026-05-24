import Foundation

public struct LuminaNoOpReActPlanner: LuminaReActPlanner {
    public init() {}

    public func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        throw LuminaNoAvailableReActPlannerError()
    }
}
