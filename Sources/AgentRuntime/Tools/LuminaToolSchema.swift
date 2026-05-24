import Foundation

public struct LuminaToolSchema: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var version: Int
    public var parameters: [LuminaToolParameterSchema]
    public var sideEffect: LuminaToolSideEffect
    public var sensitivity: LuminaToolSensitivity
    public var acceptedInputModalities: Set<LuminaAgentModality>
    public var outputModalities: Set<LuminaAgentModality>

    public init(
        name: String,
        description: String,
        version: Int = 1,
        parameters: [LuminaToolParameterSchema],
        sideEffect: LuminaToolSideEffect,
        sensitivity: LuminaToolSensitivity = .normal,
        acceptedInputModalities: Set<LuminaAgentModality> = [.text, .structuredData],
        outputModalities: Set<LuminaAgentModality> = [.text, .structuredData]
    ) {
        self.name = name
        self.description = description
        self.version = version
        self.parameters = parameters
        self.sideEffect = sideEffect
        self.sensitivity = sensitivity
        self.acceptedInputModalities = acceptedInputModalities
        self.outputModalities = outputModalities
    }
}
