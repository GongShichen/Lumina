import Foundation

public final class AnyLuminaAgentTool: LuminaAgentTool, @unchecked Sendable {
    public let schema: LuminaToolSchema
    private let callClosure: @Sendable ([String: LuminaJSONValue], LuminaCancellationToken) async throws -> LuminaToolResult
    private let contextCallClosure: @Sendable (LuminaToolExecutionContext, LuminaCancellationToken) async throws -> LuminaToolResult
    private let rollbackClosure: @Sendable (LuminaToolResult) async -> Bool

    public init<T: LuminaAgentTool>(_ tool: T) {
        self.schema = tool.schema
        self.callClosure = { arguments, cancellation in
            try await tool.call(arguments: arguments, cancellation: cancellation)
        }
        self.contextCallClosure = { context, cancellation in
            try await tool.call(context: context, cancellation: cancellation)
        }
        self.rollbackClosure = { result in
            await tool.rollback(result: result)
        }
    }

    public init(
        schema: LuminaToolSchema,
        call: @escaping @Sendable ([String: LuminaJSONValue], LuminaCancellationToken) async throws -> LuminaToolResult,
        rollback: @escaping @Sendable (LuminaToolResult) async -> Bool = { _ in false }
    ) {
        self.schema = schema
        self.callClosure = call
        self.contextCallClosure = { context, cancellation in
            try await call(context.call.arguments, cancellation)
        }
        self.rollbackClosure = rollback
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await callClosure(arguments, cancellation)
    }

    public func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await contextCallClosure(context, cancellation)
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        await rollbackClosure(result)
    }
}
