import Foundation

public struct LuminaMiniMindOModelBundleInfo: Equatable, Sendable {
    public struct ValidationError: LocalizedError, Equatable {
        public var message: String

        public var errorDescription: String? {
            message
        }
    }

    public var directory: URL
    public var architecture: String
    public var contextLength: Int
    public var vocabSize: Int
    public var hiddenSize: Int
    public var numHiddenLayers: Int
    public var eosTokenID: Int
    public var hasCompiledModel: Bool
    public var hasModelPackage: Bool

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
    ) throws -> LuminaMiniMindOModelBundleInfo {
        let config = try loadModelConfig(in: directory)
        let architecture = config.string("architecture")
            ?? config.string("model_type")
            ?? "minimind-o"
        guard architecture.hasPrefix("minimind") else {
            throw LuminaMiniMindOReActModelError.unsupportedArchitecture(architecture)
        }

        let contextLength = config.int("context_length")
            ?? config.int("max_position_embeddings")
            ?? 12_000
        if let expectedContextLength, contextLength != expectedContextLength {
            throw ValidationError(
                message: "MiniMind-o context_length is \(contextLength), expected \(expectedContextLength). Rebuild the Core ML bundle instead of editing only app code."
            )
        }

        let hasCompiledModel = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model.mlmodelc").path
        )
        let hasModelPackage = FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("model.mlpackage").path
        )
        let required = [
            "model_config.json",
            "hf_model/tokenizer.json"
        ]
        var missing = required.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        if !hasCompiledModel && !hasModelPackage {
            missing.append("model.mlmodelc or model.mlpackage")
        }
        if !missing.isEmpty {
            throw LuminaMiniMindOReActModelError.missingBundleFiles(missing)
        }

        return LuminaMiniMindOModelBundleInfo(
            directory: directory,
            architecture: architecture,
            contextLength: contextLength,
            vocabSize: config.int("vocab_size") ?? 6_400,
            hiddenSize: config.int("hidden_size") ?? 768,
            numHiddenLayers: config.int("num_hidden_layers") ?? config.int("num_layers") ?? 8,
            eosTokenID: config.int("eos_token_id") ?? 2,
            hasCompiledModel: hasCompiledModel,
            hasModelPackage: hasModelPackage
        )
    }

    private static func loadModelConfig(in directory: URL) throws -> [String: Any] {
        let candidates = [
            directory.appendingPathComponent("model_config.json"),
            directory.appendingPathComponent("hf_model/config.json")
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
        }
        throw ValidationError(message: "MiniMind-o bundle is missing model_config.json.")
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int {
            return value
        }
        if let value = self[key] as? Double {
            return Int(value)
        }
        if let value = self[key] as? String {
            return Int(value)
        }
        return nil
    }

    func string(_ key: String) -> String? {
        self[key] as? String
    }
}
