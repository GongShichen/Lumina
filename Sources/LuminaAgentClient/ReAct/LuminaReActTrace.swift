import Foundation

public struct LuminaReActTrace: Codable, Hashable, Sendable {
    public var steps: [LuminaReActStep]
    public var terminationReason: String?
    public var compactedActionCount: Int
    public var compactionCount: Int

    public init(
        steps: [LuminaReActStep] = [],
        terminationReason: String? = nil,
        compactedActionCount: Int = 0,
        compactionCount: Int = 0
    ) {
        self.steps = steps
        self.terminationReason = terminationReason
        self.compactedActionCount = compactedActionCount
        self.compactionCount = compactionCount
    }

    public var actionCount: Int {
        compactedActionCount + steps.filter { $0.kind == .action }.count
    }

    public var observations: [LuminaReActObservation] {
        steps.compactMap(\.observation)
    }
}
