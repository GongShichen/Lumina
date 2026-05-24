import Foundation

public struct LuminaAuditRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var requestID: UUID
    public var toolName: String
    public var schemaVersion: Int
    public var arguments: [String: LuminaJSONValue]
    public var permission: String
    public var confirmed: Bool
    public var resultStatus: LuminaToolResultStatus
    public var outputSummary: String
    public var errorMessage: String?
    public var rollbackStatus: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        requestID: UUID,
        toolName: String,
        schemaVersion: Int,
        arguments: [String: LuminaJSONValue],
        permission: String,
        confirmed: Bool,
        resultStatus: LuminaToolResultStatus,
        outputSummary: String,
        errorMessage: String? = nil,
        rollbackStatus: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.requestID = requestID
        self.toolName = toolName
        self.schemaVersion = schemaVersion
        self.arguments = arguments
        self.permission = permission
        self.confirmed = confirmed
        self.resultStatus = resultStatus
        self.outputSummary = outputSummary
        self.errorMessage = errorMessage
        self.rollbackStatus = rollbackStatus
    }
}
