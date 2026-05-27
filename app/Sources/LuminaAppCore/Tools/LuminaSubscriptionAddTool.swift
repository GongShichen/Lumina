import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaSubscriptionAddTool: LuminaAgentTool {
    public let store: LuminaSubscriptionStore
    public let memoryStore: LuminaMemoryStore

    public init(store: LuminaSubscriptionStore, memoryStore: LuminaMemoryStore) {
        self.store = store
        self.memoryStore = memoryStore
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "subscription.add",
            description: "添加内容订阅，并写入本地记忆索引。",
            parameters: [LuminaToolParameterSchema(name: "source", type: .string, description: "RSS 或 URL。")],
            sideEffect: .appLocalWrite,
            sensitivity: .normal,
            acceptedInputModalities: [.text, .file, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await addSubscription(arguments: arguments, requestMetadata: [:], cancellation: cancellation)
    }

    public func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await addSubscription(arguments: context.call.arguments, requestMetadata: context.request.metadata, cancellation: cancellation)
    }

    private func addSubscription(
        arguments: [String: LuminaJSONValue],
        requestMetadata: [String: LuminaJSONValue],
        cancellation: LuminaCancellationToken
    ) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let source = arguments.string("source") ?? ""
        let id = await store.add(LuminaContentSubscription(source: source))
        let memoryDisabled = requestMetadata.bool("lumina.disable_memory_context") == true ||
            requestMetadata.bool("lumina.evaluation.memory_access_disabled") == true
        if !memoryDisabled {
            await memoryStore.ingest(LuminaMemoryDocument(
                source: LuminaMemorySource(kind: .subscription, identifier: id),
                title: "Subscription",
                body: source,
                sensitivity: .normal
            ))
        }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id), "memoryWriteSkipped": .bool(memoryDisabled)],
            content: [.text("订阅已添加：\(source)")],
            rollbackToken: id
        )
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}
