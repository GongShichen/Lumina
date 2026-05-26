import Foundation

public struct LuminaNoAvailableReActStepGeneratorError: LocalizedError, Sendable {
    public init() {}

    public var errorDescription: String? {
        "No available ReAct step generator."
    }
}
