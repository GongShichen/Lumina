import Foundation

public struct LuminaStructuredInferenceProgress: Codable, Hashable, Sendable {
    public var phase: String
    public var elapsedMilliseconds: Double
    public var promptTokens: Int?
    public var sampledTokens: Int?
    public var outputTokens: Int
    public var partialOutput: String?

    public init(
        phase: String,
        elapsedMilliseconds: Double,
        promptTokens: Int? = nil,
        sampledTokens: Int? = nil,
        outputTokens: Int = 0,
        partialOutput: String? = nil
    ) {
        self.phase = phase
        self.elapsedMilliseconds = elapsedMilliseconds
        self.promptTokens = promptTokens
        self.sampledTokens = sampledTokens
        self.outputTokens = outputTokens
        self.partialOutput = partialOutput
    }
}
