import Foundation

public struct LuminaRuntimeTiming: Codable, Hashable, Sendable {
    public var planningMilliseconds: Double
    public var toolExecutionMilliseconds: Double
    public var totalMilliseconds: Double

    public init(
        planningMilliseconds: Double = 0,
        toolExecutionMilliseconds: Double = 0,
        totalMilliseconds: Double = 0
    ) {
        self.planningMilliseconds = planningMilliseconds
        self.toolExecutionMilliseconds = toolExecutionMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}
