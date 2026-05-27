import Foundation

public protocol LuminaAgentTool: Sendable {
    var schema: LuminaToolSchema { get }
    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult
    func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult
    func rollback(result: LuminaToolResult) async -> Bool
}
