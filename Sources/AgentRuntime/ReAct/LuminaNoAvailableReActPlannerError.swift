import Foundation

public struct LuminaNoAvailableReActPlannerError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "No available ReAct planner."
    }
}
