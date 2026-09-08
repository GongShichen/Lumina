import Foundation

public struct LuminaReActObservation: Codable, Hashable, Sendable {
    public var toolName: String
    public var status: LuminaToolResultStatus
    public var summary: String
    public var output: [String: LuminaJSONValue]
    public var errorMessage: String?
    public var replayed: Bool
    public var duplicateOf: String?
    /// Opaque runtime call identity; distinct calls may have identical tool names and outputs.
    public var callID: String?

    public init(
        toolName: String,
        status: LuminaToolResultStatus,
        summary: String,
        output: [String: LuminaJSONValue] = [:],
        errorMessage: String? = nil,
        replayed: Bool = false,
        duplicateOf: String? = nil,
        callID: String? = nil
    ) {
        self.toolName = toolName
        self.status = status
        self.summary = summary
        self.output = output
        self.errorMessage = errorMessage
        self.replayed = replayed
        self.duplicateOf = duplicateOf
        self.callID = callID
    }
}
