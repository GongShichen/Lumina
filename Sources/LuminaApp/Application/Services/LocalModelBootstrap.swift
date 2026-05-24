import AgentRuntime
import Foundation
import LuminaModelRuntime
import PersonalMemory

#if canImport(CoreML)
import CoreML
#endif

enum LocalModelBootstrap {
    private enum ModelKind: String {
        case planner
        case embedding
    }

    static func makePlanner(
        readinessStore: LuminaModelReadinessStore? = nil,
        metricsStore: LuminaModelInferenceMetricsStore? = nil,
        memoryStore: LuminaMemoryStore
    ) -> any LuminaReActPlanner {
        LuminaLazyPlanner(fallback: unavailablePlanner(), readinessStore: readinessStore) {
            makeEagerPlanner(memoryStore: memoryStore, metricsStore: metricsStore)
        }
    }

    static func makeEmbeddingProvider(readinessStore: LuminaModelReadinessStore? = nil) -> any LuminaEmbeddingProvider {
        LuminaLazyEmbeddingProvider(dimension: preferredEmbeddingDimension(), readinessStore: readinessStore) {
            makeEagerEmbeddingProvider()
        }
    }

    private static func makeEagerPlanner(memoryStore: LuminaMemoryStore, metricsStore: LuminaModelInferenceMetricsStore?) -> LuminaLazyPlanner.LoadResult {
        let promptBuilder = LuminaAppReActPromptBuilder()
        #if canImport(CoreML)
        if let statefulURL = gemma4StatefulModelURL() {
            if #available(iOS 18.0, macOS 15.0, *) {
                do {
                    let model = try LuminaGemma4StatefulPlannerModel(configuration: .init(
                        modelDirectory: statefulURL,
                        computeUnits: modelComputeUnits,
                        maxNewTokens: .max,
                        expectedContextLength: 12_000,
                        outputSafetyMarginTokens: 256,
                        metricsRecorder: { metrics in
                            metricsStore?.record(metrics)
                        }
                    ))
                    log("Loaded Gemma4 stateful Core ML planner at \(statefulURL.path)")
                    let source = "Gemma4 stateful Core ML · \(model.bundleInfo.contextLength) ctx"
                    let maxOutputFrom2KPrompt = model.bundleInfo.maximumSupportedOutputTokens(
                        inputTokenCount: 2_000,
                        safetyMargin: 256,
                        configurationCap: .max
                    )
                    return .model(
                        LuminaModelBackedReActPlanner(
                            model: model,
                            promptBuilder: promptBuilder.build(context:),
                            fallback: LuminaNoOpReActPlanner()
                        ),
                        source: source,
                        message: "Gemma4 stateful Core ML planner 已连接：context \(model.bundleInfo.contextLength)，2k prompt 约可输出 \(maxOutputFrom2KPrompt) tokens，推理使用 \(modelComputeUnits.descriptionForLumina)。"
                    )
                } catch {
                    log("Gemma4 stateful Core ML planner failed to initialize: \(error.localizedDescription)")
                    return .fallback(
                        unavailablePlanner(),
                        message: "Gemma4 planner 初始化失败：\(error.localizedDescription)。当前没有可用模型 planner。"
                    )
                }
            } else {
                return .fallback(
                    unavailablePlanner(),
                    message: "当前系统版本不支持 Gemma4 stateful Core ML planner；当前没有可用模型 planner。"
                )
            }
        }

        if let url = firstModelURL(kind: .planner, candidates: ["Gemma4Planner", "LocalPlanner"]),
           let model = try? LuminaCoreMLTextToJSONModel(configuration: .init(
               modelURL: url,
               promptInputName: "prompt",
               jsonOutputName: "json",
               computeUnits: modelComputeUnits
           )) {
            log("Loaded Gemma/local planner Core ML model at \(url.path)")
            let source = url.lastPathComponent
            return .model(
                LuminaModelBackedReActPlanner(
                    model: model,
                    promptBuilder: promptBuilder.build(context:),
                    fallback: LuminaNoOpReActPlanner()
                ),
                source: source,
                message: "端侧 Core ML planner 已加载：\(url.lastPathComponent)。"
            )
        }
        #endif

        log("Planner model was not found. Requests will not be routed by app-side rules.")
        return .fallback(
            unavailablePlanner(),
            message: "没有找到 Gemma4 stateful 或 prompt-to-JSON Core ML planner；当前没有可用模型 planner。"
        )
    }

    private static func unavailablePlanner() -> any LuminaReActPlanner {
        LuminaNoOpReActPlanner()
    }

    private static func makeEagerEmbeddingProvider() -> LuminaLazyEmbeddingProvider.LoadResult {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "Gemma4Embedding", "LocalEmbedding"]) {
            if let tokenizerURL = tokenizerURL(for: url),
               let provider = try? LuminaBGECoreMLEmbeddingProvider(configuration: .init(
                   modelURL: url,
                   tokenizerURL: tokenizerURL,
                   computeUnits: modelComputeUnits,
                   normalizeOutput: true
               )) {
                log("Loaded BGE Core ML embedding model at \(url.path)")
                return .model(provider, source: url.lastPathComponent, message: "端侧 embedding 已加载：\(url.lastPathComponent)。")
            }

            if let provider = try? LuminaCoreMLEmbeddingProvider(configuration: .init(
                modelURL: url,
                textInputName: "text",
                embeddingOutputName: "embedding",
                dimension: embeddingDimension(for: url),
                computeUnits: modelComputeUnits,
                normalizeOutput: true
            )) {
                log("Loaded local embedding Core ML model at \(url.path)")
                return .model(provider, source: url.lastPathComponent, message: "端侧 embedding 已加载：\(url.lastPathComponent)。")
            }
        }

        #endif

        log("BGETextEmbedding.mlmodelc was not found. Falling back to LuminaHashingEmbeddingProvider.")
        return .fallback(
            LuminaHashingEmbeddingProvider(),
            message: "没有找到 BGETextEmbedding.mlmodelc；检索 embedding 使用确定性 hashing fallback。"
        )
    }

    private static func preferredEmbeddingDimension() -> Int {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "Gemma4Embedding", "LocalEmbedding"]) {
            return embeddingDimension(for: url)
        }
        #endif
        return LuminaHashingEmbeddingProvider().dimension
    }

    private static func tokenizerURL(for modelURL: URL) -> URL? {
        if let value = ProcessInfo.processInfo.environment["LUMINA_EMBEDDING_TOKENIZER"], !value.isEmpty {
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }

        let parent = modelURL.deletingLastPathComponent()
        let candidates = [
            parent.appendingPathComponent("tokenizer.json"),
            parent.appendingPathComponent("BGETextEmbedding-tokenizer.json"),
            parent.deletingLastPathComponent().appendingPathComponent("tokenizer.json")
        ]
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        if let url = Bundle.main.url(forResource: "BGETextEmbedding-tokenizer", withExtension: "json") {
            return url
        }
        if let url = Bundle.main.url(forResource: "tokenizer", withExtension: "json", subdirectory: "Models/BGETextEmbedding") {
            return url
        }
        return nil
    }

    private static func embeddingDimension(for url: URL) -> Int {
        url.lastPathComponent.contains("BGETextEmbedding") ? 512 : 768
    }

    private static func firstModelURL(kind: ModelKind, candidates: [String]) -> URL? {
        if let override = processEnvironmentModelURL(kind: kind), FileManager.default.fileExists(atPath: override.path) {
            return override
        }

        for candidate in candidates {
            if let url = Bundle.main.url(forResource: candidate, withExtension: "mlmodelc") {
                return url
            }
            if let url = Bundle.main.url(forResource: candidate, withExtension: "mlmodelc", subdirectory: "Models") {
                return url
            }
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(candidate).mlmodelc"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func processEnvironmentModelURL(kind: ModelKind) -> URL? {
        let key = kind == .planner ? "LUMINA_GEMMA4_PLANNER_MODEL" : "LUMINA_EMBEDDING_MODEL"
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        if kind == .embedding,
           let legacyValue = ProcessInfo.processInfo.environment["LUMINA_GEMMA4_EMBEDDING_MODEL"],
           !legacyValue.isEmpty {
            return URL(fileURLWithPath: legacyValue)
        }
        return nil
    }

    private static func gemma4StatefulModelURL() -> URL? {
        if let value = ProcessInfo.processInfo.environment["LUMINA_GEMMA4_STATEFUL_MODEL"], !value.isEmpty {
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/Gemma4Planner"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    private static func log(_ message: String) {
        #if DEBUG
        print("[Lumina][LocalModelBootstrap] \(message)")
        #endif
    }

    #if canImport(CoreML)
    private static var modelComputeUnits: MLComputeUnits {
        #if targetEnvironment(simulator)
        return .cpuOnly
        #else
        return .cpuAndNeuralEngine
        #endif
    }
    #endif
}
