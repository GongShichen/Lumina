import Foundation
import LuminaAgentRuntime
import PersonalMemory

public struct LuminaKnowledgeSearchTool: LuminaAgentTool {
    public typealias DestinationResolver =
        @Sendable () async -> LuminaKnowledgeSearchDestination

    private let knowledgeStore: LuminaKnowledgeStore
    private let destinationResolver: DestinationResolver
    private let maximumResultCharacters: Int
    private let availableCapabilityCategories: Set<String>

    public init(
        knowledgeStore: LuminaKnowledgeStore,
        maximumResultCharacters: Int,
        availableCapabilityCategories: Set<String>,
        destinationResolver: @escaping DestinationResolver
    ) {
        self.knowledgeStore = knowledgeStore
        self.maximumResultCharacters = maximumResultCharacters
        self.availableCapabilityCategories = availableCapabilityCategories
        self.destinationResolver = destinationResolver
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "knowledge.search",
            description: "搜索当前运行允许访问的产品或用户知识库，返回精简片段与引用。",
            parameters: [
                LuminaToolParameterSchema(
                    name: "query",
                    type: .string,
                    description: "要在知识库中检索的问题或关键词。",
                    sensitive: true
                ),
                LuminaToolParameterSchema(
                    name: "knowledge_base_ids",
                    type: .array,
                    description: "可选的知识库 ID 列表。",
                    required: false
                ),
                LuminaToolParameterSchema(
                    name: "limit",
                    type: .number,
                    description: "返回数量，范围 1 到 8。",
                    required: false
                )
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            idempotencyPolicy: "replay_identical",
            concurrencySafe: true,
            maxResultSize: maximumResultCharacters
        )
    }

    public func call(
        arguments: [String: LuminaJSONValue],
        cancellation: LuminaCancellationToken
    ) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let query = arguments.string("query")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let requestedLimit = Int(arguments.number("limit") ?? 5)
        let limit = min(max(requestedLimit, 1), 8)
        let baseIDs: Set<String>?
        if case let .array(values) = arguments["knowledge_base_ids"] {
            baseIDs = Set(values.compactMap(\.stringValue))
        } else {
            baseIDs = nil
        }
        let destination = await destinationResolver()
        let report = await knowledgeStore.searchWithReport(LuminaKnowledgeSearchQuery(
            text: query,
            knowledgeBaseIDs: baseIDs,
            limit: limit,
            destination: destination,
            availableCapabilityCategories: availableCapabilityCategories
        ))
        try cancellation.checkCancellation()

        var remaining = max(0, maximumResultCharacters)
        let rows: [[String: LuminaJSONValue]] = report.results.enumerated().map { offset, result in
            let allowance = max(80, remaining / max(1, report.results.count - offset))
            let snippet = String(result.chunk.summary.prefix(allowance))
            remaining = max(0, remaining - snippet.count)
            return [
                "knowledgeBaseID": .string(result.chunk.knowledgeBaseID),
                "chunkID": .string(result.chunk.id),
                "title": .string(result.chunk.title),
                "citation": .string(result.citation),
                "snippet": .string(snippet),
                "matchedBy": .string(result.matchedBy.rawValue),
                "rank": .number(Double(offset + 1))
            ]
        }
        let markdown: String
        if rows.isEmpty {
            markdown = "### 知识库检索\n\n当前访问策略允许的知识库中没有找到结果。"
        } else {
            let items = report.results.enumerated().map { offset, result in
                let snippet = String(result.chunk.summary.prefix(260))
                return "\(offset + 1). **\(result.chunk.title)** — \(snippet)\n   来源：\(result.citation)"
            }
            markdown = "### 知识库检索\n\n" + items.joined(separator: "\n\n")
        }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "results": .array(rows.map(LuminaJSONValue.object)),
                "candidateCount": .number(Double(report.candidateCount)),
                "bm25CandidateCount": .number(Double(report.bm25CandidateCount)),
                "vectorCandidateCount": .number(Double(report.vectorCandidateCount)),
                "cacheHit": .bool(report.cacheHit),
                "fallback": report.fallbackReason.map(LuminaJSONValue.string) ?? .null
            ],
            content: [.markdown(markdown)]
        )
    }
}
