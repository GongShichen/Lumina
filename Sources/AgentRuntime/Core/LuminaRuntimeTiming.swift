import Foundation

public struct LuminaRuntimeTiming: Codable, Hashable, Sendable {
    public var stepGenerationMilliseconds: Double
    public var toolExecutionMilliseconds: Double
    public var totalMilliseconds: Double

    public init(
        stepGenerationMilliseconds: Double = 0,
        toolExecutionMilliseconds: Double = 0,
        totalMilliseconds: Double = 0
    ) {
        self.stepGenerationMilliseconds = stepGenerationMilliseconds
        self.toolExecutionMilliseconds = toolExecutionMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}
