import Foundation

public struct LuminaReActObservation: Codable, Hashable, Sendable {
    public var toolName: String
    public var status: LuminaToolResultStatus
    public var summary: String
    public var errorMessage: String?

    public init(toolName: String, status: LuminaToolResultStatus, summary: String, errorMessage: String? = nil) {
        self.toolName = toolName
        self.status = status
        self.summary = summary
        self.errorMessage = errorMessage
    }
}
