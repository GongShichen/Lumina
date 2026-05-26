import LuminaAgentClient
import Foundation

public struct LuminaLedgerSearchTool: LuminaAgentTool {
    public let store: LuminaLedgerStore

    public init(store: LuminaLedgerStore) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "ledger.search",
            description: "查询 App 本地账目记录。",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "账目关键词。", required: false),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "最多返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let query = arguments.string("query")?.lowercased() ?? ""
        let limit = max(1, min(20, Int(arguments.number("limit") ?? 10)))
        let all = await store.allTransactions()
        let filtered = all
            .filter { query.isEmpty || $0.memo.lowercased().contains(query) }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(limit)
        let transactions = Array(filtered)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["transactions": .array(transactions.map(Self.jsonObject))],
            content: [.markdown(Self.markdown(transactions))]
        )
    }

    private static func jsonObject(_ transaction: LuminaLedgerTransaction) -> LuminaJSONValue {
        let amount = transaction.amount.map { NSDecimalNumber(decimal: $0).doubleValue }
        return .object([
            "id": .string(transaction.id.uuidString),
            "memo": .string(transaction.memo),
            "amount": amount.map(LuminaJSONValue.number) ?? .null,
            "createdAt": .string(ISO8601DateFormatter().string(from: transaction.createdAt))
        ])
    }

    private static func markdown(_ transactions: [LuminaLedgerTransaction]) -> String {
        guard !transactions.isEmpty else { return "## 账目\n\n没有找到匹配账目。" }
        let rows = transactions.map { transaction -> String in
            let amount = transaction.amount.map { "，金额 \(NSDecimalNumber(decimal: $0).stringValue)" } ?? ""
            return "- \(transaction.memo)\(amount)"
        }
        return "## 账目\n\n" + rows.joined(separator: "\n")
    }
}
