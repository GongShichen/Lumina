import Foundation

enum LuminaMemorySearchRanker {
    static func keywordRank(_ query: String, candidates: [LuminaMemoryChunk]) -> [LuminaMemorySearchResult] {
        let tokens = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !tokens.isEmpty else {
            return candidates.prefix(10).map { LuminaMemorySearchResult(chunk: $0, score: 0.05, matchedBy: .metadata) }
        }

        return candidates.compactMap { chunk in
            let haystack = "\(chunk.title) \(chunk.text) \(chunk.metadata.values.joined(separator: " "))".lowercased()
            let hits = tokens.reduce(0) { count, token in
                haystack.contains(token) ? count + 1 : count
            }
            guard hits > 0 else { return nil }
            return LuminaMemorySearchResult(chunk: chunk, score: Float(hits) / Float(tokens.count), matchedBy: .keyword)
        }
    }

    static func merge(
        vectorResults: [LuminaMemorySearchResult],
        keywordResults: [LuminaMemorySearchResult],
        limit: Int
    ) -> [LuminaMemorySearchResult] {
        var bestByChunk: [UUID: LuminaMemorySearchResult] = [:]
        for result in vectorResults + keywordResults {
            let current = bestByChunk[result.chunk.id]
            if current == nil || result.score > current!.score {
                bestByChunk[result.chunk.id] = result
            }
        }
        return bestByChunk.values
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.chunk.createdAt > rhs.chunk.createdAt
                }
                return lhs.score > rhs.score
            }
            .prefix(max(1, limit))
            .map { $0 }
    }
}
