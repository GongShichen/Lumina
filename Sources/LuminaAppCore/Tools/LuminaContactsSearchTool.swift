import AgentRuntime
import Foundation

public struct LuminaContactsSearchTool: LuminaAgentTool {
    public typealias SearchContacts = @Sendable (String, Int) async throws -> [LuminaContactSearchResult]

    private let searchContacts: SearchContacts

    public init(searchContacts: @escaping SearchContacts = { _, _ in [] }) {
        self.searchContacts = searchContacts
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "contacts.search",
            description: "查询本机联系人姓名、电话和邮箱，只返回最小必要字段。",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "联系人姓名或关键词。", sensitive: true),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "最多返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let query = arguments.string("query") ?? ""
        let limit = max(1, min(10, Int(arguments.number("limit") ?? 5)))
        let results = try await searchContacts(query, limit)
        try cancellation.checkCancellation()
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "contacts": .array(results.map(Self.jsonObject))
            ],
            content: [.markdown(Self.markdown(results))]
        )
    }

    private static func jsonObject(_ contact: LuminaContactSearchResult) -> LuminaJSONValue {
        .object([
            "name": .string(contact.name),
            "phones": .array(contact.phones.map(LuminaJSONValue.string)),
            "emails": .array(contact.emails.map(LuminaJSONValue.string)),
            "organization": contact.organization.map(LuminaJSONValue.string) ?? .null
        ])
    }

    private static func markdown(_ contacts: [LuminaContactSearchResult]) -> String {
        guard !contacts.isEmpty else { return "## 联系人\n\n没有找到匹配联系人。" }
        let rows = contacts.map { contact in
            let phones = contact.phones.isEmpty ? "无电话" : contact.phones.joined(separator: ", ")
            let emails = contact.emails.isEmpty ? "无邮箱" : contact.emails.joined(separator: ", ")
            return "- **\(contact.name)**：\(phones)；\(emails)"
        }
        return "## 联系人\n\n" + rows.joined(separator: "\n")
    }
}
