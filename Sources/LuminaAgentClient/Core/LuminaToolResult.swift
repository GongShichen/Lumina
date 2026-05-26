import Foundation

public struct LuminaToolResult: Codable, Hashable, Sendable {
    public var callID: UUID
    public var toolName: String
    public var status: LuminaToolResultStatus
    public var output: [String: LuminaJSONValue]
    public var content: [LuminaAgentContentPart]
    public var errorMessage: String?
    public var rollbackToken: String?

    public init(
        callID: UUID,
        toolName: String,
        status: LuminaToolResultStatus,
        output: [String: LuminaJSONValue] = [:],
        content: [LuminaAgentContentPart] = [],
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
