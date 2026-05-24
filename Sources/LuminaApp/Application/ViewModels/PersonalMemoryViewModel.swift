import Foundation
import PersonalMemory

@MainActor
final class PersonalMemoryViewModel: ObservableObject {
    @Published var query = ""
    @Published var results: [LuminaMemorySearchResult] = []
    @Published var latencyText = "idle"
    @Published var selectedSensitivity: LuminaMemorySensitivity = .privateData
    @Published var stats = LuminaMemoryIndexStats(documentCount: 0, chunkCount: 0, embeddedChunkCount: 0, cacheEntryCount: 0)
    @Published var isDeletePickerPresented = false
    @Published var pendingDeletion: MemoryDeletionRequest?

    private var memoryStore: LuminaMemoryStore?
    private var onMemoryChanged: (() async -> Void)?

    var emptyStateText: String {
        stats.chunkCount == 0 ? "暂无本地记忆" : "没有符合当前条件的记忆"
    }

    var deleteDialogMessage: String {
        results.isEmpty ? "当前筛选下没有单条可选，但你仍可以清空整个本机记忆库。" : "选择要删除的单条记忆，或清空整个本机记忆库。"
    }

    func beginDeletionFlow() {
        pendingDeletion = nil
        isDeletePickerPresented = true
    }

    func dismissDeletionFlow() {
        pendingDeletion = nil
        isDeletePickerPresented = false
    }

    func configure(memoryStore: LuminaMemoryStore, stats: LuminaMemoryIndexStats, onMemoryChanged: (() async -> Void)? = nil) {
        self.memoryStore = memoryStore
        self.stats = stats
        self.onMemoryChanged = onMemoryChanged
    }

    func refreshFromParentStats(_ stats: LuminaMemoryIndexStats) {
        self.stats = stats
    }

    func search() async {
        guard let memoryStore else { return }
        do {
            stats = await memoryStore.stats()
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                let start = ContinuousClock.now
                let chunks = await memoryStore.recentChunks(limit: 5, maximumSensitivity: selectedSensitivity)
                results = chunks.map { LuminaMemorySearchResult(chunk: $0, score: 1, matchedBy: .metadata) }
                latencyText = String(format: "%.1fms", milliseconds(since: start))
            } else {
                let report = try await memoryStore.searchWithReport(LuminaMemorySearchQuery(
                    text: trimmed,
                    limit: 5,
                    maximumSensitivity: selectedSensitivity
                ))
                results = report.results
                latencyText = String(format: "%.1fms%@", report.elapsedMilliseconds, report.cacheHit ? " cache" : "")
            }
        } catch {
            results = []
            latencyText = "failed"
        }
    }

    func requestSingleDeletion(id: UUID, title: String) {
        pendingDeletion = .one(id: id, title: title)
    }

    func requestDeleteAll() {
        pendingDeletion = .all(count: stats.chunkCount)
    }

    func delete(_ deletion: MemoryDeletionRequest) async {
        guard let memoryStore else { return }
        pendingDeletion = nil
        isDeletePickerPresented = false
        switch deletion {
        case .one(let id, _):
            _ = await memoryStore.removeChunk(id: id)
        case .all:
            _ = await memoryStore.removeAll()
        }
        await onMemoryChanged?()
        await search()
    }

    func confirmPendingDeletion() async {
        guard let deletion = pendingDeletion else { return }
        await delete(deletion)
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now)
        let components = duration.components
        return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
