import Foundation

public protocol AgentTool: Sendable {
    var schema: ToolSchema { get }
    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult
    func call(context: ToolExecutionContext, cancellation: CancellationToken) async throws -> ToolResult
    func rollback(result: ToolResult) async -> Bool
}

public extension AgentTool {
    func call(context: ToolExecutionContext, cancellation: CancellationToken) async throws -> ToolResult {
        try await call(arguments: context.call.arguments, cancellation: cancellation)
    }

    func rollback(result: ToolResult) async -> Bool { false }
}

public struct ToolExecutionContext: Sendable {
    public var request: AgentRequest
    public var call: ToolCall
    public var schema: ToolSchema

    public init(request: AgentRequest, call: ToolCall, schema: ToolSchema) {
        self.request = request
        self.call = call
        self.schema = schema
    }
}

public final class AnyAgentTool: AgentTool, @unchecked Sendable {
    public let schema: ToolSchema
    private let callClosure: @Sendable ([String: JSONValue], CancellationToken) async throws -> ToolResult
    private let contextCallClosure: @Sendable (ToolExecutionContext, CancellationToken) async throws -> ToolResult
    private let rollbackClosure: @Sendable (ToolResult) async -> Bool

    public init<T: AgentTool>(_ tool: T) {
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
        schema: ToolSchema,
        call: @escaping @Sendable ([String: JSONValue], CancellationToken) async throws -> ToolResult,
        rollback: @escaping @Sendable (ToolResult) async -> Bool = { _ in false }
    ) {
        self.schema = schema
        self.callClosure = call
        self.contextCallClosure = { context, cancellation in
            try await call(context.call.arguments, cancellation)
        }
        self.rollbackClosure = rollback
    }

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try await callClosure(arguments, cancellation)
    }

    public func call(context: ToolExecutionContext, cancellation: CancellationToken) async throws -> ToolResult {
        try await contextCallClosure(context, cancellation)
    }

    public func rollback(result: ToolResult) async -> Bool {
        await rollbackClosure(result)
    }
}

public struct CancellationToken: Sendable {
    public init() {}

    public func checkCancellation() throws {
        try Task.checkCancellation()
    }
}
