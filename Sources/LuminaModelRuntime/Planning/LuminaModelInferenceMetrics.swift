import Foundation

public struct LuminaModelInferenceMetrics: Codable, Hashable, Sendable {
    public var id: UUID
    public var modelName: String
    public var computeUnits: String
    public var contextLength: Int
    public var promptTokens: Int
    public var outputTokens: Int
    public var maxOutputTokens: Int
    public var timeToFirstTokenMilliseconds: Double?
    public var generationMilliseconds: Double
    public var totalMilliseconds: Double
    public var tokensPerSecond: Double
    public var loadMilliseconds: Double
    public var tokenizerMilliseconds: Double
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        modelName: String,
        computeUnits: String,
        contextLength: Int,
        promptTokens: Int,
        outputTokens: Int,
        maxOutputTokens: Int,
        timeToFirstTokenMilliseconds: Double?,
        generationMilliseconds: Double,
        totalMilliseconds: Double,
        tokensPerSecond: Double,
        loadMilliseconds: Double,
        tokenizerMilliseconds: Double,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.modelName = modelName
        self.computeUnits = computeUnits
        self.contextLength = contextLength
        self.promptTokens = promptTokens
        self.outputTokens = outputTokens
        self.maxOutputTokens = maxOutputTokens
        self.timeToFirstTokenMilliseconds = timeToFirstTokenMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.tokensPerSecond = tokensPerSecond
        self.loadMilliseconds = loadMilliseconds
        self.tokenizerMilliseconds = tokenizerMilliseconds
        self.createdAt = createdAt
    }
}
