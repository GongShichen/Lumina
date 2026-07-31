import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaAppContextProvider: LuminaRuntimeContextProvider {
    public static let disableMemoryContextMetadataKey = "lumina.disable_memory_context"

    private let memoryStore: LuminaMemoryStore
    private var maximumSnippets: Int

    public init(memoryStore: LuminaMemoryStore, maximumSnippets: Int = 4) {
        self.memoryStore = memoryStore
        self.maximumSnippets = maximumSnippets
    }

    public func loadContext(_ request: LuminaRuntimeContextRequest) async throws -> LuminaRuntimeContext {
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

public struct LuminaAppContextLoadingPlugin: LuminaContextLoadingPlugin {
    public typealias DestinationResolver =
        @Sendable () async -> LuminaKnowledgeSearchDestination

    private struct Request: Decodable {
        struct ReasoningStep: Decodable {
            var thinking: String?
        }

        struct Budget: Decodable {
            var remainingTokensEstimate: Int?

            enum CodingKeys: String, CodingKey {
                case remainingTokensEstimate = "remaining_tokens_estimate"
            }
        }

        struct ContextMetadata: Decodable {
            var id: String?
            var hash: String?
        }

        struct Item: Codable {
            var id: String
            var source: String?
            var title: String?
            var summary: String?
            var version: String?
            var citation: String?
            var hash: String?
            var tokenEstimate: Int?

            enum CodingKeys: String, CodingKey {
                case id, source, title, summary, version, citation, hash
                case tokenEstimate = "token_estimate"
            }
        }

        var action: String
        var query: String?
        var request: LuminaAgentRequest?
        var reasoningStep: ReasoningStep?
        var contextBudget: Budget?
        var loadedContextSet: [ContextMetadata]
        var items: [Item]
        var source: String?
        var knowledgeBaseID: String?

        enum CodingKeys: String, CodingKey {
            case action, query, request, source, items
            case reasoningStep = "reasoning_step"
            case contextBudget = "context_budget"
            case loadedContextSet = "loaded_context_set"
            case knowledgeBaseID = "knowledge_base_id"
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            action = try values.decode(String.self, forKey: .action)
            query = try values.decodeIfPresent(String.self, forKey: .query)
            request = try values.decodeIfPresent(LuminaAgentRequest.self, forKey: .request)
            reasoningStep = try values.decodeIfPresent(ReasoningStep.self, forKey: .reasoningStep)
            contextBudget = try values.decodeIfPresent(Budget.self, forKey: .contextBudget)
            loadedContextSet = try values.decodeIfPresent([ContextMetadata].self, forKey: .loadedContextSet) ?? []
            items = try values.decodeIfPresent([Item].self, forKey: .items) ?? []
            source = try values.decodeIfPresent(String.self, forKey: .source)
            knowledgeBaseID = try values.decodeIfPresent(String.self, forKey: .knowledgeBaseID)
        }
    }

    private struct Section: Encodable {
        var id: String
        var title: String
        var summary: String
        var content: String
        var source: String
        var sensitivity: LuminaToolSensitivity
        var disclosureLevel: Int
        var hash: String
        var tokenEstimate: Int

        enum CodingKeys: String, CodingKey {
            case id, title, summary, content, source, sensitivity, hash
            case disclosureLevel = "disclosure_level"
            case tokenEstimate = "token_estimate"
        }
    }

    private struct Response: Encodable {
        var status: String
        var items: [Request.Item]?
        var sections: [Section]?
        var nextCursor: String?
        var failureReason: String?

        enum CodingKeys: String, CodingKey {
            case status, items, sections
            case nextCursor = "next_cursor"
            case failureReason = "failure_reason"
        }
    }

    private let knowledgeStore: LuminaKnowledgeStore
    private let destinationResolver: DestinationResolver
    private let configuration: LuminaAgentRuntimeConfiguration
    private let availableCapabilityCategories: Set<String>

    public init(
        knowledgeStore: LuminaKnowledgeStore,
        configuration: LuminaAgentRuntimeConfiguration,
        availableCapabilityCategories: Set<String>,
        destinationResolver: @escaping DestinationResolver
    ) {
        self.knowledgeStore = knowledgeStore
        self.configuration = configuration
        self.availableCapabilityCategories = availableCapabilityCategories
        self.destinationResolver = destinationResolver
    }

    public func handleContextLoading(requestJSON: String) async -> String {
        do {
            let request = try JSONDecoder().decode(Request.self, from: Data(requestJSON.utf8))
            let destination = await destinationResolver()
            switch request.action.lowercased() {
            case "catalog":
                let descriptors = await knowledgeStore.descriptors(
                    destination: destination,
                    includeDisabled: false
                )
                return encode(Response(
                    status: "ok",
                    items: descriptors.map { descriptor in
                        Request.Item(
                            id: "knowledge-base:\(descriptor.id)",
                            source: descriptor.origin.rawValue,
                            title: descriptor.title,
                            summary: descriptor.summary,
                            version: descriptor.version,
                            citation: nil,
                            hash: "\(descriptor.id)@\(descriptor.version)",
                            tokenEstimate: max(8, (descriptor.title.count + descriptor.summary.count) / 4)
                        )
                    },
                    sections: nil,
                    nextCursor: nil,
                    failureReason: nil
                ))
            case "search":
                return await search(request, destination: destination)
            case "load":
                return await load(request, destination: destination)
            case "range":
                return await range(request, destination: destination)
            case "invalidate":
                await knowledgeStore.invalidateCaches(
                    knowledgeBaseID: request.knowledgeBaseID ?? baseID(fromSource: request.source)
                )
                return encode(Response(
                    status: "ok",
                    items: nil,
                    sections: nil,
                    nextCursor: nil,
                    failureReason: nil
                ))
            default:
                return encode(Response(
                    status: "skipped",
                    items: nil,
                    sections: nil,
                    nextCursor: nil,
                    failureReason: nil
                ))
            }
        } catch {
            return encode(Response(
                status: "failed",
                items: nil,
                sections: nil,
                nextCursor: nil,
                failureReason: error.localizedDescription
            ))
        }
    }

    private func search(
        _ request: Request,
        destination: LuminaKnowledgeSearchDestination
    ) async -> String {
        let query = request.reasoningStep?.thinking?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let original = request.request?.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedQuery = (query?.isEmpty == false ? query : nil)
            ?? (original?.isEmpty == false ? original : nil)
            ?? request.query
            ?? ""
        let loadedIDs = Set(request.loadedContextSet.compactMap(\.id))
        let loadedHashes = Set(request.loadedContextSet.compactMap(\.hash))
        let report = await knowledgeStore.searchWithReport(LuminaKnowledgeSearchQuery(
            text: resolvedQuery,
            limit: 8,
            destination: destination,
            availableCapabilityCategories: availableCapabilityCategories
        ))
        let items = report.results.compactMap { result -> Request.Item? in
            let id = "knowledge:\(result.chunk.knowledgeBaseID):\(result.chunk.id)"
            guard !loadedIDs.contains(id), !loadedHashes.contains(result.chunk.contentHash) else {
                return nil
            }
            return Request.Item(
                id: id,
                source: "knowledge-base:\(result.chunk.knowledgeBaseID)",
                title: result.chunk.title,
                summary: result.chunk.summary,
                version: nil,
                citation: result.citation,
                hash: result.chunk.contentHash,
                tokenEstimate: max(8, result.chunk.text.count / 4)
            )
        }
        return encode(Response(
            status: "ok",
            items: items,
            sections: nil,
            nextCursor: nil,
            failureReason: nil
        ))
    }

    private func load(
        _ request: Request,
        destination: LuminaKnowledgeSearchDestination
    ) async -> String {
        let loadedIDs = Set(request.loadedContextSet.compactMap(\.id))
        let loadedHashes = Set(request.loadedContextSet.compactMap(\.hash))
        var remaining = maximumCharacters(for: request)
        var sections: [Section] = []
        for item in request.items {
            guard !loadedIDs.contains(item.id),
                  let reference = reference(fromItemID: item.id),
                  let expectedHash = item.hash,
                  let chunk = await knowledgeStore.chunk(
                    id: reference.chunkID,
                    expectedContentHash: expectedHash,
                    destination: destination
                  ),
                  chunk.knowledgeBaseID == reference.baseID,
                  !loadedHashes.contains(chunk.contentHash),
                  remaining > 0
            else { continue }
            let content = String(chunk.text.prefix(remaining))
            remaining -= content.count
            sections.append(await makeSection(itemID: item.id, chunk: chunk, content: content))
        }
        return encode(Response(
            status: "ok",
            items: nil,
            sections: sections,
            nextCursor: nil,
            failureReason: nil
        ))
    }

    private func range(
        _ request: Request,
        destination: LuminaKnowledgeSearchDestination
    ) async -> String {
        guard let item = request.items.first,
              let currentReference = reference(fromItemID: item.id),
              let expectedHash = item.hash,
              let current = await knowledgeStore.chunk(
                id: currentReference.chunkID,
                expectedContentHash: expectedHash,
                destination: destination
              ),
              current.knowledgeBaseID == currentReference.baseID
        else {
            return encode(Response(
                status: "ok",
                items: nil,
                sections: [],
                nextCursor: nil,
                failureReason: nil
            ))
        }
        let loadedIDs = Set(request.loadedContextSet.compactMap(\.id))
        let rawLoadedChunkIDs = Set(loadedIDs.compactMap { reference(fromItemID: $0)?.chunkID })
        let chunks = await knowledgeStore.adjacentChunks(
            to: currentReference.chunkID,
            before: 1,
            after: 2,
            excluding: rawLoadedChunkIDs,
            destination: destination
        )
        var remaining = maximumCharacters(for: request)
        var sections: [Section] = []
        for chunk in chunks where remaining > 0 {
            let itemID = "knowledge:\(chunk.knowledgeBaseID):\(chunk.id)"
            let content = String(chunk.text.prefix(remaining))
            remaining -= content.count
            sections.append(await makeSection(itemID: itemID, chunk: chunk, content: content))
        }
        let nextCursor = sections.count < chunks.count
            ? "\(currentReference.chunkID):\(sections.count)"
            : nil
        return encode(Response(
            status: "ok",
            items: nil,
            sections: sections,
            nextCursor: nextCursor,
            failureReason: nil
        ))
    }

    private func makeSection(
        itemID: String,
        chunk: LuminaKnowledgeChunk,
        content: String
    ) async -> Section {
        let descriptor = await knowledgeStore.descriptor(id: chunk.knowledgeBaseID)
        let sensitivity: LuminaToolSensitivity = descriptor?.origin == .bundled ? .normal : .privateData
        let baseTitle = descriptor?.title ?? chunk.knowledgeBaseID
        return Section(
            id: itemID,
            title: chunk.title,
            summary: chunk.summary,
            content: content,
            source: "\(baseTitle) · \(chunk.locator.citation)",
            sensitivity: sensitivity,
            disclosureLevel: 1,
            hash: chunk.contentHash,
            tokenEstimate: max(1, content.count / 4)
        )
    }

    private func maximumCharacters(for request: Request) -> Int {
        guard let remainingTokens = request.contextBudget?.remainingTokensEstimate else {
            return configuration.maximumObservationCharacters
        }
        let tokenCharacters = max(0, remainingTokens) * 4
        return min(configuration.maximumObservationCharacters, tokenCharacters)
    }

    private func reference(fromItemID value: String) -> (baseID: String, chunkID: String)? {
        let prefix = "knowledge:"
        guard value.hasPrefix(prefix) else { return nil }
        let payload = value.dropFirst(prefix.count)
        guard let separator = payload.lastIndex(of: ":"),
              separator > payload.startIndex,
              separator < payload.index(before: payload.endIndex)
        else { return nil }
        return (
            baseID: String(payload[..<separator]),
            chunkID: String(payload[payload.index(after: separator)...])
        )
    }

    private func baseID(fromSource value: String?) -> String? {
        guard let value, value.hasPrefix("knowledge-base:") else { return nil }
        return String(value.dropFirst("knowledge-base:".count))
    }

    private func encode(_ response: Response) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(response),
              let value = String(data: data, encoding: .utf8)
        else {
            return #"{"status":"failed","failure_reason":"response encoding failed"}"#
        }
        return value
    }
}
