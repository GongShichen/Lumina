import LuminaAgentRuntime
import Foundation
import PersonalMemory

struct HomePersonalizationAgent {
    let memoryStore: LuminaMemoryStore
    let auditLogReader: (any LuminaAuditLogReader)?

    func generate() async -> HomeContent {
        async let stats = memoryStore.stats()
        async let recentMemory = memoryStore.recentChunks(limit: 3, maximumSensitivity: .normal)
        async let recentAudit = auditLogReader?.recentRecords(limit: 3) ?? []
        return await makeContent(
            stats: stats,
            recentMemory: recentMemory,
            recentAudit: recentAudit
        )
    }

    private func makeContent(
        stats: LuminaMemoryIndexStats,
        recentMemory: [LuminaMemoryChunk],
        recentAudit: [LuminaAuditRecord]
    ) -> HomeContent {
        let time = Self.currentTimeSnapshot()
        let period = time.dayPeriod
        let localizedTime = time.localizedTime
        let title = period == "你好" ? "你好，Lumina 已准备好" : "\(period)好，Lumina 已准备好"
        let subtitle = subtitleText(stats: stats, recentAudit: recentAudit, localizedTime: localizedTime)
        return HomeContent(
            greetingTitle: title,
            greetingSubtitle: subtitle,
            defaultPrompt: "",
            suggestions: []
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

    private static func currentTimeSnapshot() -> (dayPeriod: String, localizedTime: String) {
        let date = Date()
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: date)
        let dayPeriod: String
        switch hour {
        case 5..<12:
            dayPeriod = "早上"
        case 12..<18:
            dayPeriod = "下午"
        case 18..<23:
            dayPeriod = "晚上"
        default:
            dayPeriod = "你好"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return (dayPeriod, formatter.string(from: date))
    }
}
