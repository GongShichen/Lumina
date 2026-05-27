import LuminaAgentRuntime
import Foundation
import LuminaModelRuntime
import PersonalMemory

#if canImport(CoreML)
import CoreML
#endif

enum LocalModelBootstrap {
    private enum ModelKind: String {
        case structuredModel
        case embedding
    }

    static func makeStepGenerator(
        readinessStore: LuminaModelReadinessStore? = nil,
        metricsStore: LuminaModelInferenceMetricsStore? = nil,
        memoryStore: LuminaMemoryStore
    ) -> any LuminaReActStepGenerator {
        LuminaLazyReActStepGenerator(fallback: unavailableStepGenerator(), readinessStore: readinessStore) {
            makeEagerStepGenerator(memoryStore: memoryStore, metricsStore: metricsStore)
        }
    }

    static func makeEmbeddingProvider(readinessStore: LuminaModelReadinessStore? = nil) -> any LuminaEmbeddingProvider {
        LuminaLazyEmbeddingProvider(dimension: preferredEmbeddingDimension(), readinessStore: readinessStore) {
            makeEagerEmbeddingProvider()
        }
    }

    private static func makeEagerStepGenerator(memoryStore: LuminaMemoryStore, metricsStore: LuminaModelInferenceMetricsStore?) -> LuminaLazyReActStepGenerator.LoadResult {
        let promptBuilder = LuminaAppReActPromptBuilder()
        if let miniCPMURL = miniCPMV46ModelURL() {
            if #available(iOS 18.0, macOS 15.0, *) {
                do {
                    let stepMaxNewTokens = 2_048
                    let model = try LuminaMiniCPMV46ReActModel(configuration: .init(
                        modelDirectory: miniCPMURL,
                        backendPreference: miniCPMV46BackendPreference,
                        maxNewTokens: stepMaxNewTokens,
                        expectedContextLength: 16_000,
                        outputSafetyMarginTokens: 256,
                        metricsRecorder: { metrics in
                            metricsStore?.record(metrics)
                        }
                    ))
                    log("Loaded MiniCPM-V 4.6 model bundle at \(miniCPMURL.path)")
                    let source = "MiniCPM-V 4.6 GGUF · \(model.bundleInfo.contextLength) ctx · \(model.bundleInfo.quantization)"
                    let maxOutputFrom2KPrompt = model.bundleInfo.maximumSupportedOutputTokens(
                        inputTokenCount: 2_000,
                        safetyMargin: 256,
                        configurationCap: stepMaxNewTokens
                    )
                    return .model(
                        LuminaModelBackedReActStepGenerator(
                            model: model,
                            promptBuilder: promptBuilder.build(context:),
                            fallback: LuminaUnavailableReActStepGenerator()
                        ),
                        source: source,
                        message: "MiniCPM-V 4.6 已连接：architecture \(model.bundleInfo.architecture)，context \(model.bundleInfo.contextLength)，\(model.bundleInfo.quantization)，动态单步输出上限当前最高 \(maxOutputFrom2KPrompt) tokens，推理入口为 LuminaModelRuntimeCore 原生 C++ engine。"
                    )
                } catch {
                    log("MiniCPM-V 4.6 model failed to initialize: \(error.localizedDescription)")
                    return .fallback(
                        unavailableStepGenerator(),
                        message: "MiniCPM-V 4.6 model 初始化失败：\(error.localizedDescription)。当前没有可用模型。"
                    )
                }
            } else {
                return .fallback(
                    unavailableStepGenerator(),
                    message: "当前系统版本不支持 MiniCPM-V 4.6；当前没有可用模型。"
                )
            }
        }

        log("Local ReAct model was not found. Requests will fail instead of using app-side rules.")
        return .fallback(
            unavailableStepGenerator(),
            message: "没有找到 MiniCPM-V 4.6 模型；当前没有可用模型。请运行 scripts/setup_models.sh 生成或安装 MiniCPMV46ReActModel。"
        )
    }

    private static func unavailableStepGenerator() -> any LuminaReActStepGenerator {
        LuminaUnavailableReActStepGenerator()
    }

    private static func makeEagerEmbeddingProvider() -> LuminaLazyEmbeddingProvider.LoadResult {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "LocalEmbedding"]) {
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
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "LocalEmbedding"]) {
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
        let key = kind == .structuredModel ? "LUMINA_MINICPMV46_MODEL" : "LUMINA_EMBEDDING_MODEL"
        if let value = ProcessInfo.processInfo.environment[key], !value.isEmpty {
            return URL(fileURLWithPath: value)
        }
        return nil
    }

    private static func miniCPMV46ModelURL() -> URL? {
        if let value = ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_MODEL"], !value.isEmpty {
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/MiniCPMV46ReActModel"),
           FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/MiniCPMV46Model"),
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
        if let override = ProcessInfo.processInfo.environment["LUMINA_COREML_COMPUTE_UNITS"]?.lowercased() {
            switch override {
            case "cpu":
                return .cpuOnly
            case "gpu", "mps", "cpuandgpu", "cpu+gpu":
                return .cpuAndGPU
            case "ane", "cpuandneuralengine", "cpu+ane":
                return .cpuAndNeuralEngine
            case "all":
                return .all
            default:
                break
            }
        }
        #if targetEnvironment(simulator)
        return .cpuOnly
        #elseif targetEnvironment(macCatalyst) || os(macOS)
        return .cpuAndGPU
        #else
        return .cpuAndNeuralEngine
        #endif
    }
    #endif

    private static var miniCPMV46BackendPreference: LuminaMiniCPMV46BackendPreference {
        switch ProcessInfo.processInfo.environment["LUMINA_MINICPMV46_BACKEND"]?.lowercased() {
        case "ane":
            return .ane
        case "mps", "metal", "gpu":
            return .mps
        default:
            return .automatic
        }
    }
}
