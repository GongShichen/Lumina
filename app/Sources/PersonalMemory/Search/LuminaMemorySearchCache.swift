import Foundation

struct LuminaMemorySearchCache: Sendable {
    private var entries: [String: [LuminaMemorySearchResult]] = [:]
    private let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int {
        entries.count
    }

    func results(for query: LuminaMemorySearchQuery) -> [LuminaMemorySearchResult]? {
        entries[Self.key(for: query)]
    }

    mutating func remember(_ results: [LuminaMemorySearchResult], for query: LuminaMemorySearchQuery) {
        let key = Self.key(for: query)
        if entries.count >= limit {
            entries.removeValue(forKey: entries.keys.sorted().first ?? key)
        }
        entries[key] = results
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
    }

    private static func key(for query: LuminaMemorySearchQuery) -> String {
        let sources = query.sourceKinds?.map(\.rawValue).sorted().joined(separator: ",") ?? "*"
        return [
            query.text,
            String(query.limit),
            sources,
            query.since?.timeIntervalSince1970.description ?? "",
            query.until?.timeIntervalSince1970.description ?? "",
            query.maximumSensitivity.rawValue
        ].joined(separator: "|")
    }
}
