import LuminaAgentClient
@preconcurrency import EventKit
import Foundation
import PersonalMemory

struct LuminaSubscriptionAddTool: LuminaAgentTool {
    let store: LuminaSubscriptionStore
    let memoryStore: LuminaMemoryStore

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "subscription.add",
            description: "添加内容订阅，并写入本地记忆索引。",
            parameters: [
                LuminaToolParameterSchema(name: "source", type: .string, description: "RSS 或 URL。")
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .normal,
            acceptedInputModalities: [.text, .file, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await addSubscription(arguments: arguments, requestMetadata: [:], cancellation: cancellation)
    }

    func call(context: LuminaToolExecutionContext, cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try await addSubscription(arguments: context.call.arguments, requestMetadata: context.request.metadata, cancellation: cancellation)
    }

    private func addSubscription(
        arguments: [String: LuminaJSONValue],
        requestMetadata: [String: LuminaJSONValue],
        cancellation: LuminaCancellationToken
    ) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let source = arguments.string("source") ?? ""
        let subscription = LuminaContentSubscription(source: source)
        let id = await store.add(subscription)
        let memoryDisabled = requestMetadata.bool(LuminaAppContextProvider.disableMemoryContextMetadataKey) == true ||
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

    func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}
