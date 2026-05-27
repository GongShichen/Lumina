import LuminaAgentRuntime
import Foundation

struct LuminaLazyReActStepGenerator: LuminaReActStepGenerator {
    private let loader: Loader
    private let readinessStore: LuminaModelReadinessStore?

    init(
        fallback: any LuminaReActStepGenerator,
        readinessStore: LuminaModelReadinessStore? = nil,
        load: @escaping @Sendable () -> LoadResult
    ) {
        self.readinessStore = readinessStore
        self.loader = Loader(fallback: fallback, readinessStore: readinessStore, load: load)
    }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        let result = await loader.stepGenerator()
        switch result.source {
        case "Model unavailable":
            await readinessStore?.markModelFallback(result.message)
        default:
            await readinessStore?.markModelRun(source: result.source)
        }
        let model = result.stepGenerator
        return try await model.nextStep(context: context)
    }

    struct LoadResult: Sendable {
        var stepGenerator: any LuminaReActStepGenerator
        var source: String
        var message: String

        static func fallback(_ stepGenerator: any LuminaReActStepGenerator, message: String) -> LoadResult {
            LoadResult(stepGenerator: stepGenerator, source: "Model unavailable", message: message)
        }

        static func model(_ stepGenerator: any LuminaReActStepGenerator, source: String, message: String) -> LoadResult {
            LoadResult(stepGenerator: stepGenerator, source: source, message: message)
        }
    }

    private actor Loader {
        private let fallback: any LuminaReActStepGenerator
        private let readinessStore: LuminaModelReadinessStore?
        private var cachedResult: LoadResult?
        private var loadTask: Task<LoadResult, Never>?
        private let load: @Sendable () -> LoadResult

        init(
            fallback: any LuminaReActStepGenerator,
            readinessStore: LuminaModelReadinessStore?,
            load: @escaping @Sendable () -> LoadResult
        ) {
            self.fallback = fallback
            self.readinessStore = readinessStore
            self.load = load
        }

        func stepGenerator() async -> LoadResult {
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
                    if result.source == "Model unavailable" {
                        await readinessStore?.markModelUnavailable(result.message)
                    } else {
                        await readinessStore?.markModelReady(source: result.source, message: result.message)
                    }
                }
            }
            guard let task = loadTask else {
                return .fallback(fallback, message: "端侧模型加载状态异常；当前没有可用模型。")
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
