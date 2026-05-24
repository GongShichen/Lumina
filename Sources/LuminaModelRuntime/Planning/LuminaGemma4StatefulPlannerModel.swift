import AgentRuntime
import Foundation

#if canImport(CoreML) && canImport(CoreMLLLM) && canImport(Tokenizers)
import CoreML
import CoreMLLLM
import Tokenizers

@available(iOS 18.0, macOS 15.0, *)
public final class LuminaGemma4StatefulPlannerModel: LuminaLocalStructuredInferenceModel, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelDirectory: URL
        public var computeUnits: MLComputeUnits
        public var maxNewTokens: Int
        public var expectedContextLength: Int
        public var outputSafetyMarginTokens: Int
        public var metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)?

        public init(
            modelDirectory: URL,
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
            maxNewTokens: Int = .max,
            expectedContextLength: Int = 12_000,
            outputSafetyMarginTokens: Int = 256,
            metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)? = nil
        ) {
            self.modelDirectory = modelDirectory
            self.computeUnits = computeUnits
            self.maxNewTokens = maxNewTokens
            self.expectedContextLength = expectedContextLength
            self.outputSafetyMarginTokens = outputSafetyMarginTokens
            self.metricsRecorder = metricsRecorder
        }
    }

    private let runner: Runner
    public let bundleInfo: LuminaGemma4StatefulBundleInfo

    public init(configuration: Configuration) throws {
        try Self.validateBundle(at: configuration.modelDirectory)
        self.bundleInfo = try LuminaGemma4StatefulBundleInfo.inspect(
            directory: configuration.modelDirectory,
            expectedContextLength: configuration.expectedContextLength
        )
        self.runner = Runner(configuration: configuration)
    }

    public func generateJSON(prompt: String) async throws -> String {
        try Task.checkCancellation()
        let generated = try await runner.generate(prompt: prompt)
        return try Self.extractJSONObject(from: generated)
    }

    private static func validateBundle(at directory: URL) throws {
        let required = [
            "model_config.json",
            "hf_model/tokenizer.json",
            "chunk_1.mlmodelc",
            "chunk_2.mlmodelc",
            "chunk_3.mlmodelc",
            "embed_tokens_q8.bin",
            "embed_tokens_scales.bin",
            "embed_tokens_per_layer_q8.bin",
            "embed_tokens_per_layer_scales.bin",
            "per_layer_projection.bin",
            "per_layer_norm_weight.bin",
            "cos_sliding.npy",
            "sin_sliding.npy",
            "cos_full.npy",
            "sin_full.npy"
        ]
        let missing = required.filter {
            !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        if !missing.isEmpty {
            throw LuminaGemma4StatefulPlannerModelError.missingBundleFiles(missing)
        }
    }

    private static func extractJSONObject(from generated: String) throws -> String {
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.first == "{", trimmed.last == "}" {
            return try canonicalReActJSONObject(from: trimmed)
        }

        if let fenced = extractFencedJSON(from: trimmed) {
            return try canonicalReActJSONObject(from: fenced)
        }

        if let balanced = extractBalancedJSONObject(from: trimmed) {
            return try canonicalReActJSONObject(from: balanced)
        }

        throw LuminaGemma4StatefulPlannerModelError.missingJSONObject(generated)
    }

    private static func canonicalReActJSONObject(from json: String) throws -> String {
        let data = Data(json.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return json
        }

        if let type = object["type"] as? String,
           ["thought", "tool_use", "final_answer"].contains(type.lowercased()) {
            return json
        }

        let canonicalData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: canonicalData, as: UTF8.self)
    }

    private static func extractFencedJSON(from text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.range(of: "```") else { return nil }
        var body = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("json") {
            body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body.first == "{" && body.last == "}" ? body : nil
    }

    private static func extractBalancedJSONObject(from text: String) -> String? {
        var startIndex: String.Index?
        var depth = 0
        var isInsideString = false
        var isEscaped = false

        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                index = text.index(after: index)
                continue
            }

            if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                if depth == 0 {
                    startIndex = index
                }
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0, let startIndex {
                    let endIndex = text.index(after: index)
                    return String(text[startIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private actor Runner {
        private let configuration: Configuration
        private var engine: Gemma4StatefulEngine?
        private var tokenizer: (any Tokenizer)?

        init(configuration: Configuration) {
            self.configuration = configuration
        }

        func generate(prompt: String) async throws -> String {
            try Task.checkCancellation()
            let totalStart = ContinuousClock.now
            let loadStart = ContinuousClock.now
            let engine = try await loadedEngine()
            let loadMilliseconds = Self.milliseconds(since: loadStart)
            let tokenizerStart = ContinuousClock.now
            let tokenizer = try await loadedTokenizer()
            let tokenizerMilliseconds = Self.milliseconds(since: tokenizerStart)
            let jsonPrefix = #"{"type":"#
            let chatPrompt = "<bos><|turn>user\n\(prompt)<turn|>\n<|turn>model\n\(jsonPrefix)"
            let inputIDs = tokenizer.encode(text: chatPrompt).map { Int32($0) }
            let maxNewTokens = try maximumNewTokens(forInputTokenCount: inputIDs.count, engine: engine)
            let contextLength = engine.modelConfig?.contextLength ?? configuration.expectedContextLength

            var eosTokenIDs: Set<Int32> = [1, 106]
            if let eosTokenID = tokenizer.eosTokenId {
                eosTokenIDs.insert(Int32(eosTokenID))
            }
            let skipTokenIDs: Set<Int32> = [1, 105, 106]

            var decodedTokens: [Int] = []
            var emitted = ""
            let generationStart = ContinuousClock.now
            var firstTokenMilliseconds: Double?
            _ = try await engine.generate(
                inputIds: inputIDs,
                maxNewTokens: maxNewTokens,
                eosTokenIds: eosTokenIDs
            ) { tokenID in
                guard !skipTokenIDs.contains(tokenID) else { return }
                if firstTokenMilliseconds == nil {
                    firstTokenMilliseconds = Self.milliseconds(since: generationStart)
                }
                decodedTokens.append(Int(tokenID))
                let current = tokenizer.decode(tokens: decodedTokens)
                if current.count > emitted.count {
                    emitted = current
                }
            }
            let generationMilliseconds = Self.milliseconds(since: generationStart)
            let totalMilliseconds = Self.milliseconds(since: totalStart)
            let tokensPerSecond = generationMilliseconds > 0
                ? Double(decodedTokens.count) / (generationMilliseconds / 1_000)
                : 0
            configuration.metricsRecorder?(LuminaModelInferenceMetrics(
                modelName: "Gemma4 stateful Core ML",
                computeUnits: Self.computeUnitsDescription(configuration.computeUnits),
                contextLength: contextLength,
                promptTokens: inputIDs.count,
                outputTokens: decodedTokens.count,
                maxOutputTokens: maxNewTokens,
                timeToFirstTokenMilliseconds: firstTokenMilliseconds,
                generationMilliseconds: generationMilliseconds,
                totalMilliseconds: totalMilliseconds,
                tokensPerSecond: tokensPerSecond,
                loadMilliseconds: loadMilliseconds,
                tokenizerMilliseconds: tokenizerMilliseconds
            ))
            let trimmed = emitted.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("{") {
                return trimmed
            }
            return jsonPrefix + trimmed
        }

        private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: ContinuousClock.now)
            return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }

        private nonisolated static func computeUnitsDescription(_ units: MLComputeUnits) -> String {
            switch units {
            case .cpuOnly:
                return "CPU"
            case .cpuAndGPU:
                return "CPU+GPU"
            case .cpuAndNeuralEngine:
                return "CPU+ANE"
            case .all:
                return "CPU+GPU+ANE"
            @unknown default:
                return String(describing: units)
            }
        }

        private func maximumNewTokens(forInputTokenCount inputTokenCount: Int, engine: Gemma4StatefulEngine) throws -> Int {
            let contextLength = engine.modelConfig?.contextLength ?? configuration.expectedContextLength
            let remainingContext = contextLength - inputTokenCount - configuration.outputSafetyMarginTokens
            guard remainingContext > 0 else {
                throw LuminaGemma4StatefulPlannerModelError.contextWindowExhausted(
                    inputTokens: inputTokenCount,
                    contextLength: contextLength,
                    safetyMargin: configuration.outputSafetyMarginTokens
                )
            }
            return min(configuration.maxNewTokens, remainingContext)
        }

        private func loadedEngine() async throws -> Gemma4StatefulEngine {
            if let engine {
                return engine
            }
            let engine = Gemma4StatefulEngine(config: .init(computeUnits: configuration.computeUnits))
            try await engine.load(modelDirectory: configuration.modelDirectory)
            self.engine = engine
            return engine
        }

        private func loadedTokenizer() async throws -> any Tokenizer {
            if let tokenizer {
                return tokenizer
            }
            let tokenizerDirectory = configuration.modelDirectory.appendingPathComponent("hf_model")
            let tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerDirectory)
            self.tokenizer = tokenizer
            return tokenizer
        }
    }
}

#endif
