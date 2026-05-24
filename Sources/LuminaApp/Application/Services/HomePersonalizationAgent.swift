import AgentRuntime
import Foundation
import PersonalMemory

struct HomePersonalizationAgent {
    let runtime: LuminaAgentRuntime
    let memoryStore: LuminaMemoryStore
    let auditLogReader: (any LuminaAuditLogReader)?
    let tools: [LuminaToolSchema]
    let modelReadiness: LuminaModelReadinessSnapshot

    func generate() async -> HomeContent {
        async let agentResult = runtime.run(request: LuminaAgentRequest(
            text: Self.agentPrompt,
            metadata: [LuminaAppPromptProfile.metadataKey: .string(LuminaAppPromptProfile.homePersonalization.rawValue)]
        ))
        async let stats = memoryStore.stats()
        async let recentMemory = memoryStore.recentChunks(limit: 3, maximumSensitivity: .normal)
        async let recentAudit = auditLogReader?.recentRecords(limit: 3) ?? []
        return await makeContent(
            agentResult: agentResult,
            stats: stats,
            recentMemory: recentMemory,
            recentAudit: recentAudit
        )
    }

    private func makeContent(
        agentResult: LuminaAgentRunResult,
        stats: LuminaMemoryIndexStats,
        recentMemory: [LuminaMemoryChunk],
        recentAudit: [LuminaAuditRecord]
    ) -> HomeContent {
        let time = currentTimeOutput(from: agentResult)
        let period = time["dayPeriod"]?.stringValue ?? "你好"
        let localizedTime = time["localizedTime"]?.stringValue
        let title = period == "你好" ? "你好，Lumina 已准备好" : "\(period)好，Lumina 已准备好"
        let subtitle = subtitleText(stats: stats, recentAudit: recentAudit, localizedTime: localizedTime)
        let suggestions = modelCanPersonalizeSuggestions ? suggestionsFromAgentOutput(agentResult).prefixArray(3) : []
        return HomeContent(
            greetingTitle: title,
            greetingSubtitle: subtitle,
            defaultPrompt: suggestions.first?.prompt ?? "",
            suggestions: suggestions
        )
    }

    private func subtitleText(
        stats: LuminaMemoryIndexStats,
        recentAudit: [LuminaAuditRecord],
        localizedTime: String?
    ) -> String {
        let timePrefix = localizedTime.map { "本机时间 \($0)。" } ?? ""
        if stats.chunkCount == 0 {
            return "\(timePrefix)还没有本地记忆。我可以先处理你输入的文字、图片、文件或语音。"
        }
        if let record = recentAudit.first {
            return "\(timePrefix)已有 \(stats.chunkCount) 条本地记忆；最近一次工具调用是 \(record.toolName)。"
        }
        return "\(timePrefix)已有 \(stats.chunkCount) 条本地记忆。我会优先本机检索，只把必要摘要交给 agent。"
    }

    private var modelCanPersonalizeSuggestions: Bool {
        modelReadiness.plannerState == .ready &&
            !modelReadiness.lastRunUsedFallback &&
            !modelReadiness.plannerSource.localizedCaseInsensitiveContains("fallback")
    }

    private func suggestionsFromAgentOutput(_ result: LuminaAgentRunResult) -> [HomeSuggestion] {
        let candidates = [result.plan.summary]
            + (result.reactTrace?.steps.compactMap(\.finalMarkdown) ?? [])
        return candidates.flatMap(Self.parseSuggestionLines)
    }

    private func currentTimeOutput(from result: LuminaAgentRunResult) -> [String: LuminaJSONValue] {
        result.toolResults.first { $0.toolName == "device.current_time" }?.output ?? [:]
    }

    private static let agentPrompt = """
    请为 Lumina 首页生成最多 3 条推荐 query。建议只能基于当前已注册能力和真实本机状态，不要编造任何联系人、会议、账单、地点或记忆。
    """

    private static func parseSuggestionLines(_ text: String) -> [HomeSuggestion] {
        text
            .components(separatedBy: .newlines)
            .compactMap { line -> HomeSuggestion? in
                let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 4, parts[0] == "SUGGESTION" else { return nil }
                return HomeSuggestion(title: parts[1], prompt: parts[2], icon: parts[3])
            }
    }
}
