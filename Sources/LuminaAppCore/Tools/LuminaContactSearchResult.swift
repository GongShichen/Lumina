import Foundation

public struct LuminaContactSearchResult: Codable, Hashable, Sendable {
    public var name: String
    public var phones: [String]
    public var emails: [String]
    public var organization: String?

    public init(
        name: String,
        phones: [String] = [],
        emails: [String] = [],
        organization: String? = nil
    ) {
        self.name = name
        self.phones = phones
        self.emails = emails
        self.organization = organization
    }
}
