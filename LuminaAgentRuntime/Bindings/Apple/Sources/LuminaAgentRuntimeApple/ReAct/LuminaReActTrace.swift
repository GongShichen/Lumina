import Foundation

public struct LuminaReActTrace: Codable, Hashable, Sendable {
    public var steps: [LuminaReActStep]
    public var terminationReason: String?
    public var compactedActionCount: Int
    public var compactionCount: Int
    /// The core's consumed budget, when available; proposals can exceed an interrupted batch's executed calls.
    public var consumedToolCallCount: Int?

    public init(
        steps: [LuminaReActStep] = [],
        terminationReason: String? = nil,
        compactedActionCount: Int = 0,
        compactionCount: Int = 0,
        consumedToolCallCount: Int? = nil
    ) {
        self.steps = steps
        self.terminationReason = terminationReason
        self.compactedActionCount = compactedActionCount
        self.compactionCount = compactionCount
        self.consumedToolCallCount = consumedToolCallCount
    }

    public var actionCount: Int {
        consumedToolCallCount ?? (compactedActionCount + steps.reduce(0) { count, step in
            count + (step.kind == .multiAction ? step.toolCalls.count : step.kind == .action ? 1 : 0)
        })
    }

    public var observations: [LuminaReActObservation] {
        steps.compactMap(\.observation)
    }
}
