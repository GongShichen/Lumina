import Foundation

actor LedgerStore {
    private var transactions: [LedgerTransaction] = []

    func append(_ transaction: LedgerTransaction) -> String {
        transactions.append(transaction)
        return transaction.id.uuidString
    }

    func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = transactions.count
        transactions.removeAll { $0.id == uuid }
        return transactions.count < before
    }
}

struct LedgerTransaction: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var memo: String
    var amount: Decimal?
    var createdAt = Date()
}

actor SubscriptionStore {
    private var subscriptions: [ContentSubscription] = []

    func add(_ subscription: ContentSubscription) -> String {
        subscriptions.append(subscription)
        return subscription.id.uuidString
    }

    func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = subscriptions.count
        subscriptions.removeAll { $0.id == uuid }
        return subscriptions.count < before
    }
}

struct ContentSubscription: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var source: String
    var createdAt = Date()
}
