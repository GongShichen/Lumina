import AgentRuntime
import Foundation
import PersonalMemory

public struct LuminaLedgerRecordTool: LuminaAgentTool {
    public let store: LuminaLedgerStore

    public init(store: LuminaLedgerStore) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "ledger.record",
            description: "记录 App 本地记账条目。",
            parameters: [
                LuminaToolParameterSchema(name: "memo", type: .string, description: "交易说明。", sensitive: true),
                LuminaToolParameterSchema(name: "amount", type: .number, description: "金额。", required: false)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .image, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let transaction = LuminaLedgerTransaction(
            memo: arguments.string("memo") ?? "Agent ledger item",
            amount: arguments.number("amount").map { Decimal($0) }
        )
        let id = await store.append(transaction)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id)],
            content: [.text("记账已保存：\(transaction.memo)")],
            rollbackToken: id
        )
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}
