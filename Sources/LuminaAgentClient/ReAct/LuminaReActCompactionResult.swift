import Foundation

public struct LuminaReActCompactionResult: Sendable {
    public var trace: LuminaReActTrace
    public var summary: String
    public var estimatedCharactersBefore: Int
    public var estimatedCharactersAfter: Int

    public init(
        trace: LuminaReActTrace,
        summary: String,
        estimatedCharactersBefore: Int,
        estimatedCharactersAfter: Int
    ) {
        self.trace = trace
        self.summary = summary
        self.estimatedCharactersBefore = estimatedCharactersBefore
        self.estimatedCharactersAfter = estimatedCharactersAfter
    }
}
