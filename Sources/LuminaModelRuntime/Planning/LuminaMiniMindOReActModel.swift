import AgentRuntime
import Foundation

#if canImport(CoreML) && canImport(Tokenizers)
import CoreML
import Tokenizers

@available(iOS 18.0, macOS 15.0, *)
public final class LuminaMiniMindOReActModel: LuminaLocalDynamicOutputStreamingStructuredInferenceModel, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelDirectory: URL
        public var computeUnits: MLComputeUnits
        public var maxNewTokens: Int
        public var expectedContextLength: Int
        public var outputSafetyMarginTokens: Int
        public var maximumGenerationMilliseconds: Double
        public var metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)?

        public init(
            modelDirectory: URL,
            computeUnits: MLComputeUnits = .cpuAndNeuralEngine,
            maxNewTokens: Int = .max,
            expectedContextLength: Int = 12_000,
            outputSafetyMarginTokens: Int = 256,
            maximumGenerationMilliseconds: Double = 180_000,
            metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)? = nil
        ) {
            self.modelDirectory = modelDirectory
            self.computeUnits = computeUnits
            self.maxNewTokens = maxNewTokens
            self.expectedContextLength = expectedContextLength
            self.outputSafetyMarginTokens = outputSafetyMarginTokens
            self.maximumGenerationMilliseconds = maximumGenerationMilliseconds
            self.metricsRecorder = metricsRecorder
        }
    }

    public let bundleInfo: LuminaMiniMindOModelBundleInfo
    private let runner: Runner
    private let inferenceGate = LuminaModelInferenceSerialGate()

    public init(configuration: Configuration) throws {
        self.bundleInfo = try LuminaMiniMindOModelBundleInfo.inspect(
            directory: configuration.modelDirectory,
            expectedContextLength: configuration.expectedContextLength
        )
        self.runner = Runner(configuration: configuration, bundleInfo: bundleInfo)
    }

    public func generateJSON(prompt: String) async throws -> String {
        try await generateJSON(prompt: prompt, maxOutputTokens: nil)
    }

    public func generateJSON(prompt: String, maxOutputTokens: Int?) async throws -> String {
        try Task.checkCancellation()
        let generated = try await inferenceGate.enqueue { [runner] in
            try await runner.generate(prompt: prompt, maxOutputTokens: maxOutputTokens, progress: nil)
        }
        return try Self.extractJSONObject(from: generated)
    }

    public func generateJSON(
        prompt: String,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        try await generateJSON(prompt: prompt, maxOutputTokens: nil, progress: progress)
    }

    public func generateJSON(
        prompt: String,
        maxOutputTokens: Int?,
        progress: @escaping @Sendable (LuminaStructuredInferenceProgress) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        let generated = try await inferenceGate.enqueue { [runner] in
            try await runner.generate(prompt: prompt, maxOutputTokens: maxOutputTokens, progress: progress)
        }
        return try Self.extractJSONObject(from: generated)
    }

    private static func extractJSONObject(from generated: String) throws -> String {
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        if let standard = extractFirstStandardReActJSONObject(from: trimmed) {
            return standard
        }
        if trimmed.first == "{", let canonical = try? canonicalReActJSONObject(from: trimmed) {
            return canonical
        }
        if let fenced = extractFencedJSON(from: trimmed) {
            return try canonicalReActJSONObject(from: fenced)
        }
        if let balanced = extractBalancedJSONObject(from: trimmed) {
            return try canonicalReActJSONObject(from: balanced)
        }
        throw LuminaMiniMindOReActModelError.missingJSONObject(generated)
    }

    private static func extractFirstStandardReActJSONObject(from text: String) -> String? {
        for object in extractBalancedJSONObjects(from: text) {
            if let canonical = try? canonicalReActJSONObject(from: object),
               isStandardReActJSONObject(canonical) {
                return canonical
            }
        }
        return nil
    }

    private static func isStandardReActJSONObject(_ json: String) -> Bool {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return false
        }
        switch type.lowercased() {
        case "thought":
            return object["thought"] is String
        case "tool_use":
            return object["tool_name"] is String &&
                (object["parameters"] == nil || object["parameters"] is [String: Any])
        case "final_answer":
            return object["content"] is String
        default:
            return false
        }
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
        extractBalancedJSONObjects(from: text).first
    }

    private static func extractBalancedJSONObjects(from text: String) -> [String] {
        var objects: [String] = []
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
                if depth == 0, let objectStartIndex = startIndex {
                    let endIndex = text.index(after: index)
                    objects.append(String(text[objectStartIndex..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines))
                    startIndex = nil
                }
            }
            index = text.index(after: index)
        }
        return objects
    }

    private actor Runner {
        private let configuration: Configuration
        private let bundleInfo: LuminaMiniMindOModelBundleInfo
        private var model: MLModel?
        private var state: MLState?
        private var tokenizer: (any Tokenizer)?

        init(configuration: Configuration, bundleInfo: LuminaMiniMindOModelBundleInfo) {
            self.configuration = configuration
            self.bundleInfo = bundleInfo
        }

        func generate(
            prompt: String,
            maxOutputTokens: Int?,
            progress: (@Sendable (LuminaStructuredInferenceProgress) -> Void)?
        ) async throws -> String {
            try Task.checkCancellation()
            let totalStart = ContinuousClock.now
            let loadStart = ContinuousClock.now
            let loaded = try await loadedModel()
            resetState()
            let loadMilliseconds = Self.milliseconds(since: loadStart)
            let chatPrompt = Self.miniMindPrompt(for: prompt)
            let promptTokenIDs = loaded.tokenizer.encode(text: chatPrompt)
            let promptTokens = promptTokenIDs.count
            let maxNewTokens = try maximumNewTokens(forInputTokenCount: promptTokens, override: maxOutputTokens)

            progress?(LuminaStructuredInferenceProgress(
                phase: "prompt_encoded",
                elapsedMilliseconds: Self.milliseconds(since: totalStart),
                promptTokens: promptTokens,
                outputTokens: 0,
                partialOutput: nil
            ))

            let generationStart = ContinuousClock.now
            var emitted = ""
            var outputTokens = 0
            var firstTokenMilliseconds: Double?
            var nextTokenID = 0

            for (position, tokenID) in promptTokenIDs.enumerated() {
                try Task.checkCancellation()
                nextTokenID = try predictNextToken(
                    tokenID: tokenID,
                    position: position,
                    model: loaded.model,
                    state: loaded.state
                )
            }

            var position = promptTokenIDs.count
            let eosIDs: Set<Int> = [bundleInfo.eosTokenID, 2]
            while outputTokens < maxNewTokens, position < bundleInfo.contextLength {
                try Task.checkCancellation()
                if eosIDs.contains(nextTokenID) {
                    break
                }
                if firstTokenMilliseconds == nil {
                    firstTokenMilliseconds = Self.milliseconds(since: generationStart)
                }
                outputTokens += 1
                let token = loaded.tokenizer.decode(tokens: [nextTokenID])
                emitted += token
                progress?(LuminaStructuredInferenceProgress(
                    phase: outputTokens == 1 ? "first_token" : "decoding",
                    elapsedMilliseconds: Self.milliseconds(since: generationStart),
                    promptTokens: promptTokens,
                    outputTokens: outputTokens,
                    partialOutput: emitted.truncatedForLuminaMiniMindProgress(to: 320)
                ))
                if LuminaMiniMindOReActModel.extractFirstStandardReActJSONObject(from: emitted) != nil {
                    break
                }
                nextTokenID = try predictNextToken(
                    tokenID: nextTokenID,
                    position: position,
                    model: loaded.model,
                    state: loaded.state
                )
                position += 1
                if Self.milliseconds(since: generationStart) >= configuration.maximumGenerationMilliseconds {
                    throw LuminaMiniMindOReActModelError.generationTimedOut(
                        elapsedMilliseconds: Self.milliseconds(since: generationStart),
                        outputTokens: outputTokens,
                        outputPrefix: emitted
                    )
                }
            }

            let generationMilliseconds = Self.milliseconds(since: generationStart)
            let totalMilliseconds = Self.milliseconds(since: totalStart)
            let tokensPerSecond = generationMilliseconds > 0
                ? Double(outputTokens) / (generationMilliseconds / 1_000)
                : 0
            configuration.metricsRecorder?(LuminaModelInferenceMetrics(
                modelName: "MiniMind-o Core ML",
                computeUnits: Self.computeUnitsDescription(configuration.computeUnits),
                contextLength: bundleInfo.contextLength,
                promptTokens: promptTokens,
                outputTokens: outputTokens,
                maxOutputTokens: maxNewTokens,
                timeToFirstTokenMilliseconds: firstTokenMilliseconds,
                generationMilliseconds: generationMilliseconds,
                totalMilliseconds: totalMilliseconds,
                tokensPerSecond: tokensPerSecond,
                loadMilliseconds: loadMilliseconds,
                tokenizerMilliseconds: 0
            ))
            return emitted.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func loadedModel() async throws -> LoadedModel {
            if let model, let state, let tokenizer {
                return LoadedModel(model: model, state: state, tokenizer: tokenizer)
            }
            let tokenizer = try await AutoTokenizer.from(
                modelFolder: configuration.modelDirectory.appendingPathComponent("hf_model")
            )
            let mlConfiguration = MLModelConfiguration()
            mlConfiguration.computeUnits = configuration.computeUnits
            let modelURL = try modelArtifactURL()
            let model: MLModel
            if modelURL.pathExtension == "mlmodelc" {
                model = try MLModel(contentsOf: modelURL, configuration: mlConfiguration)
            } else {
                let compiledURL = try await MLModel.compileModel(at: modelURL)
                model = try MLModel(contentsOf: compiledURL, configuration: mlConfiguration)
            }
            let state = model.makeState()
            self.model = model
            self.state = state
            self.tokenizer = tokenizer
            return LoadedModel(model: model, state: state, tokenizer: tokenizer)
        }

        private func resetState() {
            state = model?.makeState()
        }

        private func modelArtifactURL() throws -> URL {
            let compiled = configuration.modelDirectory.appendingPathComponent("model.mlmodelc")
            if FileManager.default.fileExists(atPath: compiled.path) {
                return compiled
            }
            let package = configuration.modelDirectory.appendingPathComponent("model.mlpackage")
            if FileManager.default.fileExists(atPath: package.path) {
                return package
            }
            throw LuminaMiniMindOReActModelError.missingBundleFiles(["model.mlmodelc or model.mlpackage"])
        }

        private func predictNextToken(
            tokenID: Int,
            position: Int,
            model: MLModel,
            state: MLState
        ) throws -> Int {
            let contextLength = bundleInfo.contextLength
            let ids = try MLMultiArray(shape: [1, 1], dataType: .int32)
            ids[[0, 0] as [NSNumber]] = NSNumber(value: Int32(tokenID))

            let positions = try MLMultiArray(shape: [1], dataType: .int32)
            positions[0] = NSNumber(value: Int32(position))

            let causalMask = try MLMultiArray(
                shape: [1, 1, 1, NSNumber(value: contextLength)],
                dataType: .float16
            )
            let causalPointer = causalMask.dataPointer.bindMemory(to: UInt16.self, capacity: contextLength)
            for index in 0..<contextLength {
                causalPointer[index] = index <= position ? 0 : 0xFC00
            }

            let updateMask = try MLMultiArray(
                shape: [1, 1, NSNumber(value: contextLength), 1],
                dataType: .float16
            )
            let updatePointer = updateMask.dataPointer.bindMemory(to: UInt16.self, capacity: contextLength)
            memset(updatePointer, 0, contextLength * MemoryLayout<UInt16>.stride)
            updatePointer[min(position, contextLength - 1)] = 0x3C00

            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids),
                "position_ids": MLFeatureValue(multiArray: positions),
                "causal_mask": MLFeatureValue(multiArray: causalMask),
                "update_mask": MLFeatureValue(multiArray: updateMask)
            ])
            let output = try model.prediction(from: provider, using: state)
            guard let token = output.featureValue(for: "token_id")?.multiArrayValue?[0].intValue else {
                throw LuminaMiniMindOReActModelError.missingTokenIDOutput
            }
            return token
        }

        private struct LoadedModel {
            var model: MLModel
            var state: MLState
            var tokenizer: any Tokenizer
        }

        private nonisolated static func miniMindPrompt(for prompt: String) -> String {
            """
            <|im_start|>user
            \(prompt)<|im_end|>
            <|im_start|>assistant
            """
        }

        private func maximumNewTokens(forInputTokenCount inputTokenCount: Int, override: Int?) throws -> Int {
            let remainingContext = bundleInfo.contextLength - inputTokenCount - configuration.outputSafetyMarginTokens
            guard remainingContext > 0 else {
                throw LuminaMiniMindOReActModelError.contextWindowExhausted(
                    inputTokens: inputTokenCount,
                    contextLength: bundleInfo.contextLength,
                    safetyMargin: configuration.outputSafetyMarginTokens
                )
            }
            let requested = override.map { max(1, min($0, configuration.maxNewTokens)) } ?? configuration.maxNewTokens
            return min(requested, remainingContext)
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
                return "CPU+GPU/MPS"
            case .cpuAndNeuralEngine:
                return "CPU+ANE"
            case .all:
                return "CPU+GPU/MPS+ANE"
            @unknown default:
                return String(describing: units)
            }
        }
    }
}

private extension String {
    func truncatedForLuminaMiniMindProgress(to limit: Int) -> String {
        guard count > limit else { return self }
        return String(prefix(limit))
    }
}
#endif
