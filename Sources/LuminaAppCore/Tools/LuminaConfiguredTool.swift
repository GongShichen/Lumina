import AgentRuntime
import Foundation

public struct LuminaConfiguredTool: LuminaAgentTool {
    public typealias Handler = @Sendable ([String: LuminaJSONValue], LuminaCancellationToken) async throws -> LuminaToolResult
    public typealias RollbackHandler = @Sendable (LuminaToolResult) async -> Bool

    public let schema: LuminaToolSchema
    private let handler: Handler
    private let rollbackHandler: RollbackHandler?

    public init(
        schema: LuminaToolSchema,
        handler: @escaping Handler,
        rollback: RollbackHandler? = nil
    ) {
        self.schema = schema
        self.handler = handler
        self.rollbackHandler = rollback
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await handler(arguments, cancellation)
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let rollbackHandler else { return false }
        return await rollbackHandler(result)
    }
}
