import Foundation

enum LuminaMemorySearchRanker {
    static func merge(
        bm25Results: [LuminaBM25Hit<UUID>],
        vectorIDs: [UUID],
        chunksByID: [UUID: LuminaMemoryChunk],
        limit: Int
    ) -> [LuminaMemorySearchResult] {
        let candidateLimit = max(limit * 8, 40)
        return LuminaReciprocalRankFusion.merge(
            bm25IDs: bm25Results.prefix(candidateLimit).map(\.id),
            vectorIDs: Array(vectorIDs.prefix(candidateLimit)),
            limit: max(1, limit)
        ).compactMap { hit in
            guard let chunk = chunksByID[hit.id] else { return nil }
            let matchedBy: LuminaMemoryMatchKind
            if hit.bm25Rank != nil && hit.vectorRank != nil {
                matchedBy = .hybrid
            } else if hit.bm25Rank != nil {
                matchedBy = .bm25
            } else {
                matchedBy = .vector
            }
            return LuminaMemorySearchResult(
                chunk: chunk,
                score: hit.score,
                matchedBy: matchedBy,
                bm25Rank: hit.bm25Rank,
                vectorRank: hit.vectorRank
            )
        }
    }
}
