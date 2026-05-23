import AgentRuntime
import Foundation
import PersonalMemory

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
               computeUnits: .all
           )) {
            log("Loaded Gemma/local planner Core ML model at \(url.path)")
            return Gemma4CoreMLPlanner(model: model)
        }
        #endif

        log("Gemma4Planner.mlmodelc was not found. Falling back to FoundationModelsPlanner.")
        return FoundationModelsPlanner()
    }

    static func makeEmbeddingProvider() -> any EmbeddingProvider {
        #if canImport(CoreML)
        if let url = firstModelURL(kind: .embedding, candidates: ["BGETextEmbedding", "Gemma4Embedding", "LocalEmbedding"]),
           let provider = try? CoreMLEmbeddingProvider(configuration: .init(
               modelURL: url,
               textInputName: "text",
               embeddingOutputName: "embedding",
               dimension: embeddingDimension(for: url),
               computeUnits: .all,
               normalizeOutput: true
           )) {
            log("Loaded local embedding Core ML model at \(url.path)")
            return provider
        }
        #endif

        log("BGETextEmbedding.mlmodelc was not found. Falling back to HashingEmbeddingProvider.")
        return HashingEmbeddingProvider()
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

    private static func log(_ message: String) {
        #if DEBUG
        print("[Lumina][LocalModelBootstrap] \(message)")
        #endif
    }
}
