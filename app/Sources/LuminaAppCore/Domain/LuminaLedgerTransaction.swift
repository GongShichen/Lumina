import Foundation

public struct LuminaLedgerTransaction: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var memo: String
    public var amount: Decimal?
    public var createdAt: Date

    public init(id: UUID = UUID(), memo: String, amount: Decimal? = nil, createdAt: Date = Date()) {
        self.id = id
        self.memo = memo
        self.amount = amount
        self.createdAt = createdAt
    }
}
