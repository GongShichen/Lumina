import LuminaAgentRuntime
import Foundation
import PersonalMemory

struct LuminaAppContextProvider: LuminaRuntimeContextProvider {
    static let disableMemoryContextMetadataKey = "lumina.disable_memory_context"

    let memoryStore: LuminaMemoryStore
    var maximumSnippets: Int = 4

    func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext {
        try Task.checkCancellation()
        if request.request.metadata.bool(Self.disableMemoryContextMetadataKey) == true {
            return .empty
        }
        let query = request.request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard shouldLoadMemory(for: query, trace: request.trace) else {
            return .empty
        }

        let limit = min(maximumSnippets, max(1, request.maximumCharacters / 600))
        let results: [LuminaMemorySearchResult]
        if query.isEmpty {
            let recent = await memoryStore.recentChunks(limit: limit, maximumSensitivity: .privateData)
            results = recent.map { LuminaMemorySearchResult(chunk: $0, score: 0.05, matchedBy: .metadata) }
        } else {
            results = try await memoryStore.search(LuminaMemorySearchQuery(
                text: query,
                limit: limit,
                maximumSensitivity: .privateData
            ))
        }

        var remaining = request.maximumCharacters
        let sections = results.compactMap { result -> LuminaRuntimeContextSection? in
            guard remaining > 120 else { return nil }
            let chunk = result.chunk
            let summary = chunk.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let content = String(summary.prefix(min(summary.count, remaining)))
            remaining -= content.count
            return LuminaRuntimeContextSection(
                id: "memory:\(chunk.id.uuidString)",
                title: chunk.title,
                summary: summary,
                content: content,
                source: "\(chunk.source.kind.rawValue)/\(chunk.source.identifier)",
                sensitivity: sensitivity(for: chunk.sensitivity),
                disclosureLevel: 0
            )
        }
        return LuminaRuntimeContext(sections: sections)
    }

    private func shouldLoadMemory(for query: String, trace: LuminaReActTrace) -> Bool {
        if trace.actionCount > 0 {
            return false
        }
        if query.isEmpty {
            return true
        }
        let text = query.lowercased()
        return text.contains("记忆") ||
            text.contains("查") ||
            text.contains("找") ||
            text.contains("search") ||
            text.contains("会议") ||
            text.contains("日程") ||
            text.contains("账") ||
            text.contains("订阅") ||
            text.contains("总结") ||
            text.contains("之前")
    }

    private func sensitivity(for sensitivity: LuminaMemorySensitivity) -> LuminaToolSensitivity {
        switch sensitivity {
        case .low:
            return .low
        case .normal:
            return .normal
        case .sensitive:
            return .sensitive
        case .privateData:
            return .privateData
        }
    }
}
