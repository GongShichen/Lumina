import Foundation

public struct LuminaStepGenerationProgress: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var iteration: Int
    public var elapsedMilliseconds: Double
    public var message: String
    public var promptTokens: Int?
    public var sampledTokens: Int?
    public var outputTokens: Int
    public var partialOutput: String?

    public init(
        requestID: UUID,
        iteration: Int,
        elapsedMilliseconds: Double,
        message: String,
        promptTokens: Int? = nil,
        sampledTokens: Int? = nil,
        outputTokens: Int = 0,
        partialOutput: String? = nil
    ) {
        self.requestID = requestID
        self.iteration = iteration
        self.elapsedMilliseconds = elapsedMilliseconds
        self.message = message
        self.promptTokens = promptTokens
        self.sampledTokens = sampledTokens
        self.outputTokens = outputTokens
        self.partialOutput = partialOutput
    }
}
