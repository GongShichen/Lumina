import Foundation

public actor LuminaLedgerStore {
    private var transactions: [LuminaLedgerTransaction] = []
    private let url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL? = nil) {
        self.url = url
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ transaction: LuminaLedgerTransaction) -> String {
        transactions.append(transaction)
        try? persist()
        return transaction.id.uuidString
    }

    public func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = transactions.count
        transactions.removeAll { $0.id == uuid }
        let removed = transactions.count < before
        if removed {
            try? persist()
        }
        return removed
    }

    public func update(id: String, memo: String?, amount: Decimal?) -> LuminaLedgerTransaction? {
        guard let uuid = UUID(uuidString: id),
              let index = transactions.firstIndex(where: { $0.id == uuid }) else {
            return nil
        }
        var transaction = transactions[index]
        if let memo, !memo.isEmpty {
            transaction.memo = memo
        }
        if let amount {
            transaction.amount = amount
        }
        transactions[index] = transaction
        try? persist()
        return transaction
    }

    public func allTransactions() -> [LuminaLedgerTransaction] {
        transactions
    }

    public func load() async throws {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        transactions = try decoder.decode([LuminaLedgerTransaction].self, from: data)
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(transactions)
        try data.write(to: url, options: .atomic)
    }
}
