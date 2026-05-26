import Foundation

public extension LuminaAgentTool {
    func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await call(arguments: context.call.arguments, cancellation: cancellation)
    }

    func rollback(result: LuminaToolResult) async -> Bool {
        false
    }
}
