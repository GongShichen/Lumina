import Foundation

public actor LuminaSubscriptionStore {
    private var subscriptions: [LuminaContentSubscription] = []
    private let url: URL?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL? = nil) {
        self.url = url
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func add(_ subscription: LuminaContentSubscription) -> String {
        subscriptions.append(subscription)
        try? persist()
        return subscription.id.uuidString
    }

    public func remove(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = subscriptions.count
        subscriptions.removeAll { $0.id == uuid }
        let removed = subscriptions.count < before
        if removed {
            try? persist()
        }
        return removed
    }

    public func allSubscriptions() -> [LuminaContentSubscription] {
        subscriptions
    }

    public func load() async throws {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        subscriptions = try decoder.decode([LuminaContentSubscription].self, from: data)
    }

    private func persist() throws {
        guard let url else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(subscriptions)
        try data.write(to: url, options: .atomic)
    }
}
