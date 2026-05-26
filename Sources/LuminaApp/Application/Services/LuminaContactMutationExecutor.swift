import LuminaAgentClient
@preconcurrency import Contacts
import Foundation

#if canImport(UIKit)
import UIKit
#endif

enum LuminaContactMutationExecutor {
    static func createContact(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let store = CNContactStore()
        try await requestAccess(store: store)
        let contact = CNMutableContact()
        let name = arguments.string("name") ?? "Lumina Contact"
        let parts = name.split(separator: " ", maxSplits: 1).map(String.init)
        contact.givenName = parts.last ?? name
        contact.familyName = parts.count > 1 ? parts[0] : ""
        if let phone = arguments.string("phone"), !phone.isEmpty {
            contact.phoneNumbers = [CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone))]
        }
        if let email = arguments.string("email"), !email.isEmpty {
            contact.emailAddresses = [CNLabeledValue(label: CNLabelHome, value: email as NSString)]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        try store.execute(request)
        return result("contacts.create", status: .succeeded, message: "联系人已创建：\(name)", output: [
            "identifier": .string(contact.identifier),
            "name": .string(name)
        ])
    }

    static func updateContact(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let store = CNContactStore()
        try await requestAccess(store: store)
        guard let contact = try findContact(arguments: arguments, store: store)?.mutableCopy() as? CNMutableContact else {
            return result("contacts.update", status: .failed, message: "没有找到要更新的联系人。", output: [:])
        }
        if let phone = arguments.string("phone"), !phone.isEmpty {
            contact.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMobile, value: CNPhoneNumber(stringValue: phone)))
        }
        if let email = arguments.string("email"), !email.isEmpty {
            contact.emailAddresses.append(CNLabeledValue(label: CNLabelHome, value: email as NSString))
        }
        if let organization = arguments.string("organization") {
            contact.organizationName = organization
        }
        let request = CNSaveRequest()
        request.update(contact)
        try store.execute(request)
        return result("contacts.update", status: .succeeded, message: "联系人已更新。", output: ["identifier": .string(contact.identifier)])
    }

    static func openContact(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let query = arguments.string("query") ?? ""
        #if canImport(UIKit)
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let candidates = [
            URL(string: "contacts://show?\(encoded)"),
            URL(string: "x-apple.systempreferences:com.apple.Contacts")
        ].compactMap { $0 }
        for url in candidates {
            let opened = await MainActor.run { UIApplication.shared.canOpenURL(url) }
            if opened {
                return await withCheckedContinuation { continuation in
                    DispatchQueue.main.async {
                        UIApplication.shared.open(url) { success in
                            continuation.resume(returning: result("contacts.open", status: success ? .succeeded : .failed, message: success ? "已打开联系人入口。" : "当前平台无法打开联系人入口。", output: ["query": .string(query)]))
                        }
                    }
                }
            }
        }
        #endif
        return result("contacts.open", status: .failed, message: "当前平台无法打开联系人入口。", output: ["query": .string(query)])
    }

    private static func requestAccess(store: CNContactStore) async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited:
            return
        case .notDetermined:
            guard try await LuminaPermissionTimingRecorder.shared.record({
                try await store.requestAccess(for: .contacts)
            }) else {
                throw AppToolError.permissionDenied("通讯录权限未开启。请在系统设置中允许 Lumina 访问通讯录后重试。")
            }
        case .denied, .restricted:
            throw AppToolError.permissionDenied("通讯录权限已被拒绝。请在系统设置中允许 Lumina 访问通讯录后重试。")
        @unknown default:
            throw AppToolError.permissionDenied("当前系统无法确认通讯录权限。")
        }
    }

    private static func findContact(arguments: [String: LuminaJSONValue], store: CNContactStore) throws -> CNContact? {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor
        ]
        if let id = arguments.string("id"), !id.isEmpty {
            return try store.unifiedContact(withIdentifier: id, keysToFetch: keys)
        }
        guard let name = arguments.string("name"), !name.isEmpty else { return nil }
        return try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys).first
    }

    private static func result(_ tool: String, status: LuminaToolResultStatus, message: String, output: [String: LuminaJSONValue]) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: tool,
            status: status,
            output: output.merging(["summary": .string(message)]) { current, _ in current },
            content: [.markdown(message)],
            errorMessage: status == .failed ? message : nil
        )
    }
}
