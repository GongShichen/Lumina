import Foundation
import PersonalMemory

@MainActor
final class KnowledgeBaseViewModel: ObservableObject {
    @Published var descriptors: [LuminaKnowledgeBaseDescriptor] = []
    @Published var stats = LuminaKnowledgeStats.empty
    @Published var query = ""
    @Published var results: [LuminaKnowledgeSearchResult] = []
    @Published var latencyText = "idle"
    @Published var importPhase: LuminaKnowledgeImportPhase?
    @Published var errorMessage: String?
    @Published var loadFailures: [String] = []

    private var knowledgeStore: LuminaKnowledgeStore?

    var bundled: [LuminaKnowledgeBaseDescriptor] {
        descriptors.filter { $0.origin == .bundled }
    }

    var imported: [LuminaKnowledgeBaseDescriptor] {
        descriptors.filter { $0.origin == .userImported }
    }

    func configure(knowledgeStore: LuminaKnowledgeStore) {
        self.knowledgeStore = knowledgeStore
        Task { await refresh() }
    }

    func refresh() async {
        guard let knowledgeStore else { return }
        descriptors = await knowledgeStore.descriptors()
        stats = await knowledgeStore.stats()
        loadFailures = await knowledgeStore.failures()
    }

    func documents(for baseID: String) async -> [LuminaKnowledgeDocument] {
        guard let knowledgeStore else { return [] }
        return await knowledgeStore.documents(knowledgeBaseID: baseID)
    }

    func search(baseID: String? = nil) async {
        guard let knowledgeStore else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            results = []
            latencyText = "idle"
            return
        }
        let report = await knowledgeStore.searchWithReport(LuminaKnowledgeSearchQuery(
            text: trimmed,
            knowledgeBaseIDs: baseID.map { [$0] },
            limit: baseID == nil ? 12 : 20,
            destination: .local,
            includeDisabled: baseID != nil
        ))
        results = report.results
        latencyText = String(
            format: "%.1fms · B%d/V%d%@",
            report.elapsedMilliseconds,
            report.bm25CandidateCount,
            report.vectorCandidateCount,
            report.cacheHit ? " · cache" : ""
        )
    }

    func create(title: String, fileURLs: [URL]) async {
        guard let knowledgeStore else { return }
        errorMessage = nil
        do {
            _ = try await knowledgeStore.importKnowledgeBase(
                title: title,
                fileURLs: fileURLs,
                progress: progressHandler()
            )
            importPhase = .complete
            await refresh()
            await search()
        } catch {
            importPhase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func addDocuments(baseID: String, fileURLs: [URL]) async {
        guard let knowledgeStore else { return }
        errorMessage = nil
        do {
            _ = try await knowledgeStore.addDocuments(
                to: baseID,
                fileURLs: fileURLs,
                progress: progressHandler()
            )
            importPhase = .complete
            await refresh()
        } catch {
            importPhase = .failed
            errorMessage = error.localizedDescription
        }
    }

    func setEnabled(_ enabled: Bool, baseID: String) async {
        guard let knowledgeStore else { return }
        do {
            try await knowledgeStore.setEnabled(enabled, knowledgeBaseID: baseID)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setRemoteAccess(_ access: LuminaKnowledgeRemoteAccess, baseID: String) async {
        guard let knowledgeStore else { return }
        do {
            try await knowledgeStore.setRemoteAccess(access, knowledgeBaseID: baseID)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func removeDocument(id: String, baseID: String) async {
        guard let knowledgeStore else { return }
        do {
            try await knowledgeStore.removeDocument(id: id, knowledgeBaseID: baseID)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteBase(id: String) async {
        guard let knowledgeStore else { return }
        do {
            try await knowledgeStore.deleteKnowledgeBase(id: id)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func retryIndexing() async {
        guard let knowledgeStore else { return }
        await knowledgeStore.reload()
        await refresh()
    }

    private func progressHandler() -> @Sendable (LuminaKnowledgeImportPhase) -> Void {
        { [weak self] phase in
            Task { @MainActor in
                self?.importPhase = phase
            }
        }
    }
}
