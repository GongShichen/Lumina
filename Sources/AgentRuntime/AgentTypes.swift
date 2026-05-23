import Foundation

public struct AgentRequest: Codable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var content: [AgentContentPart]
    public var localeIdentifier: String
    public var metadata: [String: JSONValue]

    public init(
        id: UUID = UUID(),
        text: String,
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.text = text
        self.content = [.text(text)]
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }

    public init(
        id: UUID = UUID(),
        content: [AgentContentPart],
        localeIdentifier: String = Locale.current.identifier,
        metadata: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.content = content
        self.text = content.textForPlanning
        self.localeIdentifier = localeIdentifier
        self.metadata = metadata
    }
}

public struct AgentPlan: Codable, Hashable, Sendable {
    public var id: UUID
    public var summary: String
    public var toolCalls: [ToolCall]

    public init(id: UUID = UUID(), summary: String, toolCalls: [ToolCall]) {
        self.id = id
        self.summary = summary
        self.toolCalls = toolCalls
    }
}

public struct AgentRunResult: Codable, Hashable, Sendable {
    public var requestID: UUID
    public var plan: AgentPlan
    public var toolResults: [ToolResult]
    public var status: AgentRunStatus
    public var timing: RuntimeTiming
    public var reactTrace: ReActTrace?

    public init(
        requestID: UUID,
        plan: AgentPlan,
        toolResults: [ToolResult],
        status: AgentRunStatus,
        timing: RuntimeTiming = RuntimeTiming(),
        reactTrace: ReActTrace? = nil
    ) {
        self.requestID = requestID
        self.plan = plan
        self.toolResults = toolResults
        self.status = status
        self.timing = timing
        self.reactTrace = reactTrace
    }
}

public enum AgentRunStatus: String, Codable, Sendable {
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
}

public enum AgentRunEvent: Sendable {
    case planningStarted(UUID)
    case planCreated(AgentPlan)
    case thoughtGenerated(ReActStep)
    case actionProposed(ToolCall)
    case observationCreated(ReActObservation)
    case finalGenerated(String)
    case permissionChecked(ToolCall, PermissionDecision)
    case confirmationRequired(ToolCall)
    case confirmationResolved(ToolCall, Bool)
    case toolStarted(ToolCall)
    case toolFinished(ToolResult)
    case rollbackStarted(ToolCall)
    case rollbackFinished(ToolCall, Bool)
    case finished(AgentRunResult)
}

public struct ToolCall: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var toolName: String
    public var arguments: [String: JSONValue]
    public var requiresConfirmation: Bool

    public init(
        id: UUID = UUID(),
        toolName: String,
        arguments: [String: JSONValue],
        requiresConfirmation: Bool = false
    ) {
        self.id = id
        self.toolName = toolName
        self.arguments = arguments
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct ToolResult: Codable, Hashable, Sendable {
    public var callID: UUID
    public var toolName: String
    public var status: ToolResultStatus
    public var output: [String: JSONValue]
    public var content: [AgentContentPart]
    public var errorMessage: String?
    public var rollbackToken: String?

    public init(
        callID: UUID,
        toolName: String,
        status: ToolResultStatus,
        output: [String: JSONValue] = [:],
        content: [AgentContentPart] = [],
        errorMessage: String? = nil,
        rollbackToken: String? = nil
    ) {
        self.callID = callID
        self.toolName = toolName
        self.status = status
        self.output = output
        self.content = content
        self.errorMessage = errorMessage
        self.rollbackToken = rollbackToken
    }
}

public enum ToolResultStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
    case denied
}
