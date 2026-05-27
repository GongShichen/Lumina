import Foundation

public struct LuminaMiniCPMV46ModelBundleInfo: Equatable, Sendable {
    public struct ValidationError: LocalizedError, Equatable {
        public var message: String

        public var errorDescription: String? {
            message
        }
    }

    public var directory: URL
    public var architecture: String
    public var contextLength: Int
    public var quantization: String
    public var modelURL: URL
    public var projectorURL: URL?
    public var sourceRepository: String

    public var hasVisionProjector: Bool {
        projectorURL != nil
    }

    public func maximumSupportedOutputTokens(
        inputTokenCount: Int,
        safetyMargin: Int,
        configurationCap: Int
    ) -> Int {
        let remaining = max(0, contextLength - inputTokenCount - safetyMargin)
        return min(configurationCap, remaining)
    }

    public static func inspect(
        directory: URL,
        expectedContextLength: Int? = nil
    ) throws -> LuminaMiniCPMV46ModelBundleInfo {
        let config = try loadModelConfig(in: directory)
        let architecture = config.string("architecture")
            ?? config.string("model_type")
            ?? "minicpm-v-4_6"
        guard architecture.hasPrefix("minicpm") else {
            throw LuminaMiniCPMV46ReActModelError.unsupportedArchitecture(architecture)
        }

        let contextLength = config.int("context_length")
            ?? config.int("max_position_embeddings")
            ?? 16_000
        if let expectedContextLength, contextLength != expectedContextLength {
            throw ValidationError(
                message: "MiniCPM-V 4.6 context_length is \(contextLength), expected \(expectedContextLength). Rebuild the model bundle instead of editing only app code."
            )
        }

        let modelURL = try resolveTextModelURL(in: directory, config: config)
        let projectorURL = resolveProjectorURL(in: directory, config: config)
        var missing = ["model_config.json"].filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        if !FileManager.default.fileExists(atPath: modelURL.path) {
            missing.append(modelURL.lastPathComponent)
        }
        if !missing.isEmpty {
            throw LuminaMiniCPMV46ReActModelError.missingBundleFiles(missing)
        }

        return LuminaMiniCPMV46ModelBundleInfo(
            directory: directory,
            architecture: architecture,
            contextLength: contextLength,
            quantization: config.string("quantization") ?? inferQuantization(from: modelURL),
            modelURL: modelURL,
            projectorURL: projectorURL,
            sourceRepository: config.string("source_repo") ?? "openbmb/MiniCPM-V-4_6-gguf"
        )
    }

    private static func loadModelConfig(in directory: URL) throws -> [String: Any] {
        let configURL = directory.appendingPathComponent("model_config.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            throw ValidationError(message: "MiniCPM-V 4.6 bundle is missing model_config.json.")
        }
        let data = try Data(contentsOf: configURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ValidationError(message: "MiniCPM-V 4.6 model_config.json must be a JSON object.")
        }
        return object
    }

    private static func resolveTextModelURL(in directory: URL, config: [String: Any]) throws -> URL {
        if let relativePath = config.string("text_model") ?? config.string("model_file") {
            return directory.appendingPathComponent(relativePath)
        }
        let candidates = [
            "model.gguf",
            "MiniCPM-V-4_6-F16.gguf",
            "MiniCPM-V-4_6-Q8_0.gguf",
            "MiniCPM-V-4_6-Q6_K.gguf",
            "MiniCPM-V-4_6-Q5_K_M.gguf",
            "MiniCPM-V-4_6-Q4_K_M.gguf",
            "MiniCPM-V-4_6-Q5_1.gguf",
            "MiniCPM-V-4_6-Q5_0.gguf"
        ]
        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        throw LuminaMiniCPMV46ReActModelError.missingBundleFiles(["model.gguf or MiniCPM-V-4_6-*.gguf"])
    }

    private static func resolveProjectorURL(in directory: URL, config: [String: Any]) -> URL? {
        let candidates = [
            config.string("vision_projector"),
            config.string("mmproj_file"),
            "mmproj-model-f16.gguf"
        ].compactMap { $0 }
        for candidate in candidates {
            let url = directory.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func inferQuantization(from url: URL) -> String {
        let name = url.deletingPathExtension().lastPathComponent
        if let range = name.range(of: "Q", options: [.caseInsensitive, .backwards]) {
            return String(name[range.lowerBound...])
        }
        return "unknown"
    }
}
