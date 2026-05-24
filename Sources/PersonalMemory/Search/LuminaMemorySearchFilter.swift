import Foundation

enum LuminaMemorySearchFilter {
    static func candidates(for query: LuminaMemorySearchQuery, in chunks: [LuminaMemoryChunk]) -> [LuminaMemoryChunk] {
        chunks.lazy.filter { chunk in
            if let sourceKinds = query.sourceKinds, !sourceKinds.contains(chunk.source.kind) {
                return false
            }
            if let since = query.since, chunk.createdAt < since {
                return false
            }
            if let until = query.until, chunk.createdAt > until {
                return false
            }
            if chunk.sensitivity > query.maximumSensitivity {
                return false
            }
            return true
        }.map { $0 }
    }
}
