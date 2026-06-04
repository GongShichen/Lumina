import LuminaAgentRuntime
import Foundation

public final class LuminaMiniCPMV46ReActModel: LuminaLocalDynamicOutputStreamingStructuredInferenceModel, @unchecked Sendable {
    public struct Configuration: Sendable {
        public var modelDirectory: URL
        public var backendPreference: LuminaMiniCPMV46BackendPreference
        public var maxNewTokens: Int
        public var expectedContextLength: Int
        public var outputSafetyMarginTokens: Int
        public var metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)?

        public init(
            modelDirectory: URL,
            backendPreference: LuminaMiniCPMV46BackendPreference = .automatic,
            maxNewTokens: Int = .max,
            expectedContextLength: Int = 16_000,
            outputSafetyMarginTokens: Int = 256,
            metricsRecorder: (@Sendable (LuminaModelInferenceMetrics) -> Void)? = nil
        ) {
            self.modelDirectory = modelDirectory
            self.backendPreference = backendPreference
            self.maxNewTokens = maxNewTokens
            self.expectedContextLength = expectedContextLength
            self.outputSafetyMarginTokens = outputSafetyMarginTokens
            self.metricsRecorder = metricsRecorder
        }
    }

    public let bundleInfo: LuminaMiniCPMV46ModelBundleInfo
    private let runner: Runner
    private let inferenceGate = LuminaModelInferenceSerialGate()

    public init(configuration: Configuration) throws {
        self.bundleInfo = try LuminaMiniCPMV46ModelBundleInfo.inspect(
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

    public static func nativeCapabilitiesJSON() -> String? {
        LuminaMiniCPMV46CxxEngineBridge.capabilitiesJSON()
    }

    private static func extractJSONObject(from generated: String) throws -> String {
        let trimmed = generated.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsForbiddenXMLTag(trimmed) {
            throw LuminaMiniCPMV46ReActModelError.missingJSONObject(generated)
        }
        if let standard = LuminaReActTransport.extractFirstStandardJSONObject(from: trimmed) {
            return standard
        }
        if let fenced = extractFencedJSON(from: trimmed),
           let standard = LuminaReActTransport.extractFirstStandardJSONObject(from: fenced) {
            return standard
        }
        if let fenced = extractFencedJSON(from: trimmed),
           let normalized = LuminaReActTransport.normalizeXMLTags(from: fenced) {
            return normalized
        }
        if let normalized = LuminaReActTransport.normalizeXMLTags(from: trimmed) {
            return normalized
        }
        throw LuminaMiniCPMV46ReActModelError.missingJSONObject(generated)
    }

    private static func containsForbiddenXMLTag(_ text: String) -> Bool {
        text.contains("<think") ||
            text.contains("</think>") ||
            text.contains("<tool_call") ||
            text.contains("</tool_call>") ||
            text.contains("<observation") ||
            text.contains("</observation>")
    }

    private static func extractFencedJSON(from text: String) -> String? {
        guard let start = text.range(of: "```") else { return nil }
        let tail = text[start.upperBound...]
        guard let end = tail.range(of: "```") else { return nil }
        var body = String(tail[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix("json") {
            body = String(body.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return body
    }

    private actor Runner {
        private let configuration: Configuration
        private let bundleInfo: LuminaMiniCPMV46ModelBundleInfo

        init(configuration: Configuration, bundleInfo: LuminaMiniCPMV46ModelBundleInfo) {
            self.configuration = configuration
            self.bundleInfo = bundleInfo
        }

        func generate(
            prompt: String,
            maxOutputTokens: Int?,
            progress: (@Sendable (LuminaStructuredInferenceProgress) -> Void)?
        ) async throws -> String {
            try Task.checkCancellation()
            let startedAt = ContinuousClock.now
            let promptTokens = Self.approximateTokenCount(prompt)
            let maxNewTokens = try maximumNewTokens(forInputTokenCount: promptTokens, override: maxOutputTokens)

            progress?(LuminaStructuredInferenceProgress(
                phase: "prompt_encoded",
                elapsedMilliseconds: Self.milliseconds(since: startedAt),
                promptTokens: promptTokens,
                outputTokens: 0,
                partialOutput: nil
            ))
            progress?(LuminaStructuredInferenceProgress(
                phase: "native_engine_started",
                elapsedMilliseconds: Self.milliseconds(since: startedAt),
                promptTokens: promptTokens,
                outputTokens: 0,
                partialOutput: nil
            ))

            let response = try LuminaMiniCPMV46CxxEngineBridge.generate(
                modelDirectory: bundleInfo.directory,
                backendPreference: configuration.backendPreference,
                prompt: prompt,
                contextLength: bundleInfo.contextLength,
                maxOutputTokens: maxNewTokens,
                safetyMarginTokens: configuration.outputSafetyMarginTokens
            )

            print("[Lumina][NativeEngine] Response ok: \(response.ok), output length: \(response.output?.count ?? 0), error: \(response.error ?? "none")")
            if let output = response.output {
                print("[Lumina][NativeEngine] Raw output: \(output)")
            }

            configuration.metricsRecorder?(LuminaModelInferenceMetrics(
                modelName: bundleInfo.modelName,
                computeUnits: response.backend.uppercased(),
                contextLength: response.contextLength == 0 ? bundleInfo.contextLength : response.contextLength,
                promptTokens: response.promptTokens == 0 ? promptTokens : response.promptTokens,
                outputTokens: response.outputTokens,
                maxOutputTokens: response.maxOutputTokens == 0 ? maxNewTokens : response.maxOutputTokens,
                timeToFirstTokenMilliseconds: response.timeToFirstTokenMilliseconds,
                generationMilliseconds: response.generationMilliseconds,
                totalMilliseconds: max(response.totalMilliseconds, Self.milliseconds(since: startedAt)),
                tokensPerSecond: response.tokensPerSecond,
                loadMilliseconds: 0,
                tokenizerMilliseconds: 0
            ))

            guard response.ok, let output = response.output else {
                progress?(LuminaStructuredInferenceProgress(
                    phase: "native_engine_unavailable",
                    elapsedMilliseconds: Self.milliseconds(since: startedAt),
                    promptTokens: promptTokens,
                    outputTokens: response.outputTokens,
                    partialOutput: response.error
                ))
                throw LuminaMiniCPMV46ReActModelError.engineUnavailable(
                    response.error ?? "MiniCPM-V 4.6 native engine failed without details."
                )
            }

            progress?(LuminaStructuredInferenceProgress(
                phase: "decoding_finished",
                elapsedMilliseconds: Self.milliseconds(since: startedAt),
                promptTokens: promptTokens,
                outputTokens: response.outputTokens,
                partialOutput: output.truncatedForLuminaMiniCPMProgress(to: 320)
            ))
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func maximumNewTokens(forInputTokenCount inputTokenCount: Int, override: Int?) throws -> Int {
            let remainingContext = bundleInfo.contextLength - inputTokenCount - configuration.outputSafetyMarginTokens
            guard remainingContext > 0 else {
                throw LuminaMiniCPMV46ReActModelError.contextWindowExhausted(
                    inputTokens: inputTokenCount,
                    contextLength: bundleInfo.contextLength,
                    safetyMargin: configuration.outputSafetyMarginTokens
                )
            }
            let requested = override.map { max(1, min($0, configuration.maxNewTokens)) } ?? configuration.maxNewTokens
            return min(requested, remainingContext)
        }

        private nonisolated static func approximateTokenCount(_ text: String) -> Int {
            max(1, Int(ceil(Double(text.utf8.count) / 3.6)))
        }

        private nonisolated static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let duration = start.duration(to: ContinuousClock.now)
            return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        }
    }
}
