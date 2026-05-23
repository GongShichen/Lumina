import Foundation

public actor LedgerStore {
    private var transactions: [LedgerTransaction] = []

    public init() {}

    public func append(_ transaction: LedgerTransaction) -> String {
        transactions.append(transaction)
        return transaction.id.uuidString
    }

    public func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = transactions.count
        transactions.removeAll { $0.id == uuid }
        return transactions.count < before
    }

    public func allTransactions() -> [LedgerTransaction] {
        transactions
    }
}

public struct LedgerTransaction: Identifiable, Codable, Hashable, Sendable {
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

public actor SubscriptionStore {
    private var subscriptions: [ContentSubscription] = []

    public init() {}

    public func add(_ subscription: ContentSubscription) -> String {
        subscriptions.append(subscription)
        return subscription.id.uuidString
    }

    public func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = subscriptions.count
        subscriptions.removeAll { $0.id == uuid }
        return subscriptions.count < before
    }

    public func allSubscriptions() -> [ContentSubscription] {
        subscriptions
    }
}

public struct ContentSubscription: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var source: String
    public var createdAt: Date

    public init(id: UUID = UUID(), source: String, createdAt: Date = Date()) {
        self.id = id
        self.source = source
        self.createdAt = createdAt
    }
}

public struct MessageDraft: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var recipients: [String]
    public var body: String

    public init(id: UUID = UUID(), recipients: [String], body: String) {
        self.id = id
        self.recipients = recipients
        self.body = body
    }
}

public actor MessageDraftCenter {
    private var continuation: AsyncStream<MessageDraft>.Continuation?
    private var publishedDrafts: [MessageDraft] = []

    public init() {}

    public func drafts() -> AsyncStream<MessageDraft> {
        AsyncStream { continuation in
            self.continuation = continuation
        }
    }

    public func publish(_ draft: MessageDraft) {
        publishedDrafts.append(draft)
        continuation?.yield(draft)
    }

    public func allDrafts() -> [MessageDraft] {
        publishedDrafts
    }
}
