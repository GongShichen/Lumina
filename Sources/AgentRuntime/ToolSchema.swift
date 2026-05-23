import Foundation

public struct ToolSchema: Codable, Hashable, Sendable {
    public var name: String
    public var description: String
    public var version: Int
    public var parameters: [ToolParameterSchema]
    public var sideEffect: ToolSideEffect
    public var sensitivity: ToolSensitivity
    public var acceptedInputModalities: Set<AgentModality>
    public var outputModalities: Set<AgentModality>

    public init(
        name: String,
        description: String,
        version: Int = 1,
        parameters: [ToolParameterSchema],
        sideEffect: ToolSideEffect,
        sensitivity: ToolSensitivity = .normal,
        acceptedInputModalities: Set<AgentModality> = [.text, .structuredData],
        outputModalities: Set<AgentModality> = [.text, .structuredData]
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

public struct ToolParameterSchema: Codable, Hashable, Sendable {
    public var name: String
    public var type: ToolParameterType
    public var description: String
    public var required: Bool
    public var sensitive: Bool

    public init(
        name: String,
        type: ToolParameterType,
        description: String,
        required: Bool = true,
        sensitive: Bool = false
    ) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.sensitive = sensitive
    }
}

public enum ToolParameterType: String, Codable, Sendable {
    case string
    case number
    case bool
    case dateISO8601
    case object
    case array
}

public enum ToolSideEffect: String, Codable, Sendable {
    case readOnly
    case appLocalWrite
    case systemWrite
    case externalCommunication
}

public enum ToolSensitivity: String, Codable, Sendable {
    case low
    case normal
    case sensitive
    case privateData
}
