import AgentRuntime
import Foundation

struct LuminaLazyPlanner: LuminaReActPlanner {
    private let loader: Loader
    private let readinessStore: LuminaModelReadinessStore?

    init(
        fallback: any LuminaReActPlanner,
        readinessStore: LuminaModelReadinessStore? = nil,
        load: @escaping @Sendable () -> LoadResult
    ) {
        self.readinessStore = readinessStore
        self.loader = Loader(fallback: fallback, readinessStore: readinessStore, load: load)
    }

    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        let result = await loader.planner()
        switch result.source {
        case "Planner unavailable":
            await readinessStore?.markPlannerFallback(result.message)
        default:
            await readinessStore?.markPlannerModelRun(source: result.source)
        }
        let planner = result.planner
        return try await planner.nextStep(context: context)
    }

    struct LoadResult: Sendable {
        var planner: any LuminaReActPlanner
        var source: String
        var message: String

        static func fallback(_ planner: any LuminaReActPlanner, message: String) -> LoadResult {
            LoadResult(planner: planner, source: "Planner unavailable", message: message)
        }

        static func model(_ planner: any LuminaReActPlanner, source: String, message: String) -> LoadResult {
            LoadResult(planner: planner, source: source, message: message)
        }
    }

    private actor Loader {
        private let fallback: any LuminaReActPlanner
        private let readinessStore: LuminaModelReadinessStore?
        private var cachedResult: LoadResult?
        private var loadTask: Task<LoadResult, Never>?
        private let load: @Sendable () -> LoadResult

        init(
            fallback: any LuminaReActPlanner,
            readinessStore: LuminaModelReadinessStore?,
            load: @escaping @Sendable () -> LoadResult
        ) {
            self.fallback = fallback
            self.readinessStore = readinessStore
            self.load = load
        }

        func planner() async -> LoadResult {
            if let cachedResult {
                return cachedResult
            }
            if loadTask == nil {
                let load = self.load
                let task = Task.detached(priority: .utility) {
                    load()
                }
                loadTask = task
                let readinessStore = self.readinessStore
                Task { [task, readinessStore] in
                    let result = await task.value
                    if result.source == "Planner unavailable" {
                        await readinessStore?.markPlannerUnavailable(result.message)
                    } else {
                        await readinessStore?.markPlannerReady(source: result.source, message: result.message)
                    }
                }
            }
            guard let task = loadTask else {
                return .fallback(fallback, message: "端侧 planner 模型加载状态异常；当前没有可用模型 planner。")
            }
            let result = await task.value
            cache(result)
            return result
        }

        private func cache(_ result: LoadResult) {
            cachedResult = result
            loadTask = nil
        }
    }
}
