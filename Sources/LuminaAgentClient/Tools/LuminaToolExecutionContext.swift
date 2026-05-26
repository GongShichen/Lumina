import Foundation

public struct LuminaToolExecutionContext: Sendable {
    public var request: LuminaAgentRequest
    public var call: LuminaToolCall
    public var schema: LuminaToolSchema

    public init(request: LuminaAgentRequest, call: LuminaToolCall, schema: LuminaToolSchema) {
        self.request = request
        self.call = call
        self.schema = schema
    }
}
