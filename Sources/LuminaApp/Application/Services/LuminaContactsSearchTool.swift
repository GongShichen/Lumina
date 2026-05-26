import LuminaAgentClient
@preconcurrency import Contacts
import Foundation
import LuminaAppCore

struct LuminaContactsSearchTool: LuminaAgentTool {
    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let store = CNContactStore()
        try await requestContactsAccess(store: store)
        let query = arguments.string("query") ?? ""
        let limit = max(1, min(10, Int(arguments.number("limit") ?? 5)))
        let contacts = try search(query: query, limit: limit, store: store)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["contacts": .array(contacts.map(Self.jsonObject))],
            content: [.markdown(Self.markdown(contacts))]
        )
    }

    private func requestContactsAccess(store: CNContactStore) async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = try await LuminaPermissionTimingRecorder.shared.record {
                try await store.requestAccess(for: .contacts)
            }
            if !granted {
                throw AppToolError.permissionDenied("通讯录权限未开启。请在系统设置中允许 Lumina 访问通讯录后重试。")
            }
        case .denied, .restricted:
            throw AppToolError.permissionDenied("通讯录权限已被拒绝。请在系统设置中允许 Lumina 访问通讯录后重试。")
        @unknown default:
            throw AppToolError.permissionDenied("当前系统无法确认通讯录权限，请检查设置后重试。")
        }
    }

    private func search(query: String, limit: Int, store: CNContactStore) throws -> [LuminaContactSearchResult] {
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let predicate = CNContact.predicateForContacts(matchingName: trimmed)
            return try store.unifiedContacts(matching: predicate, keysToFetch: keys)
                .prefix(limit)
                .map(Self.result)
        }
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .givenName
        var results: [LuminaContactSearchResult] = []
        try store.enumerateContacts(with: request) { contact, stop in
            results.append(Self.result(contact))
            if results.count >= limit {
                stop.pointee = true
            }
        }
        return results
    }

    private static func result(_ contact: CNContact) -> LuminaContactSearchResult {
        let fullName = CNContactFormatter.string(from: contact, style: .fullName)
        let fallback = [contact.familyName, contact.givenName, contact.nickname]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return LuminaContactSearchResult(
            name: fullName?.isEmpty == false ? fullName! : fallback,
            phones: contact.phoneNumbers.map { $0.value.stringValue },
            emails: contact.emailAddresses.map { String($0.value) },
            organization: contact.organizationName.isEmpty ? nil : contact.organizationName
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
