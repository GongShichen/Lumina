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

struct LuminaAppContextLoadingPlugin: LuminaContextLoadingPlugin {
    let contextProvider: any LuminaRuntimeContextProvider
    let tools: [AnyLuminaAgentTool]
    let configuration: LuminaAgentRuntimeConfiguration

    func handleContextLoading(requestJSON: String) async -> String {
        guard let object = try? JSONSerialization.jsonObject(with: Data(requestJSON.utf8)) as? [String: Any] else {
            return #"{"status":"failed","failure_reason":"invalid context loading request"}"#
        }
        let action = (object["action"] as? String ?? "").lowercased()
        switch action {
        case "catalog":
            return """
            {"status":"ok","items":[{"id":"memory","source":"memory","title":"Personal Memory","summary":"Host-owned personal memory snippets available through scoped search/load.","token_estimate":32}]}
            """
        case "search", "load", "range":
            return await loadSections(from: object)
        default:
            return #"{"status":"skipped"}"#
        }
    }

    private func loadSections(from object: [String: Any]) async -> String {
        do {
            let request = try decodeRequest(from: object["request"]) ?? LuminaAgentRequest(text: object["query"] as? String ?? "")
            let contextRequest = LuminaRuntimeContextRequest(
                request: request,
                availableTools: tools.map(\.schema),
                trace: LuminaReActTrace(),
                iteration: 0,
                remainingToolCalls: configuration.maximumToolCalls,
                maximumCharacters: configuration.maximumObservationCharacters
            )
            let context = try await contextProvider.loadContext(contextRequest)
            guard !context.sections.isEmpty else {
                return #"{"status":"ok","items":[],"sections":[]}"#
            }
            let data = try JSONEncoder().encode(context.sections)
            let sections = String(data: data, encoding: .utf8) ?? "[]"
            return #"{"status":"ok","sections":\#(sections)}"#
        } catch {
            return #"{"status":"failed","failure_reason":"\#(error.localizedDescription.replacingOccurrences(of: "\"", with: "\\\""))"}"#
        }
    }

    private func decodeRequest(from value: Any?) throws -> LuminaAgentRequest? {
        guard let value else { return nil }
        guard JSONSerialization.isValidJSONObject(value) else { return nil }
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(LuminaAgentRequest.self, from: data)
    }
}
