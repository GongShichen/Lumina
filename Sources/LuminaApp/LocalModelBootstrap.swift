import AgentRuntime
import Foundation
import PersonalMemory

#if canImport(CoreML)
import CoreML
#endif

enum LocalModelBootstrap {
    private enum ModelKind: String {
        case planner
        case embedding
    }

    static func makePlanner() -> any Planner {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .planner, candidates: ["Gemma4Planner", "LocalPlanner"]),
           let model = try? CoreMLTextToJSONModel(configuration: .init(
               modelURL: url,
               promptInputName: "prompt",
               jsonOutputName: "json",
               computeUnits: modelComputeUnits
           )) {
            log("Loaded Gemma/local planner Core ML model at \(url.path)")
            return Gemma4CoreMLPlanner(model: model)
        }
        if let statefulURL = gemma4StatefulModelURL() {
            log("Gemma4 stateful Core ML asset is configured at \(statefulURL.path). Stateful decode adapter is not enabled, so planner fallback remains active.")
        }
        #endif

        log("Gemma4Planner.mlmodelc was not found. Falling back to FoundationModelsPlanner.")
        return FoundationModelsPlanner()
    }

    static func makeEmbeddingProvider() -> any EmbeddingProvider {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "Gemma4Embedding", "LocalEmbedding"]) {
            if let tokenizerURL = tokenizerURL(for: url),
               let provider = try? BGECoreMLEmbeddingProvider(configuration: .init(
                   modelURL: url,
                   tokenizerURL: tokenizerURL,
                   computeUnits: modelComputeUnits,
                   normalizeOutput: true
               )) {
                log("Loaded BGE Core ML embedding model at \(url.path)")
                return provider
            }

            if let provider = try? CoreMLEmbeddingProvider(configuration: .init(
                modelURL: url,
                textInputName: "text",
                embeddingOutputName: "embedding",
                dimension: embeddingDimension(for: url),
                computeUnits: modelComputeUnits,
                normalizeOutput: true
            )) {
                log("Loaded local embedding Core ML model at \(url.path)")
                return provider
            }
        }

        #endif

        log("BGETextEmbedding.mlmodelc was not found. Falling back to HashingEmbeddingProvider.")
        return HashingEmbeddingProvider()
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
        return .all
        #endif
    }
    #endif
}
