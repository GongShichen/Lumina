import LuminaAgentRuntime
import Foundation

public struct LuminaModelBackedReActStepGenerator: LuminaReActStepGenerator {
    private let model: any LuminaLocalMultimodalStructuredInferenceModel
    private let promptBuilder: LuminaReActPromptBuilder

    public init(
        multimodalModel: any LuminaLocalMultimodalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator()
    ) {
        self.model = multimodalModel
        self.promptBuilder = promptBuilder
    }

    public init(
        model: any LuminaLocalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator()
    ) {
        self.init(
            multimodalModel: LuminaTextOnlyStructuredModelAdapter(model),
            promptBuilder: promptBuilder,
            fallback: fallback
        )
    }

    public func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        print("[Lumina][StepGenerator] nextStep started, iteration: \(context.iteration)")
        let prompt = try await promptBuilder(context)
        print("[Lumina][StepGenerator] Prompt built, length: \(prompt.count)")
        let input = LuminaStructuredStepGenerationInput(
            prompt: prompt,
            content: context.request.content,
            availableTools: context.availableTools,
            maxOutputTokensHint: Self.outputBudgetHint(for: context, repairAttempt: nil)
        )
        print("[Lumina][StepGenerator] Calling model.generateJSON...")
        let json: String
        do {
            json = try await generateJSON(input: input, context: context)
        } catch {
            print("[Lumina][StepGenerator] Generation normalization failed: \(error.localizedDescription), triggering format repair...")
            return try await repairAndParse(
                invalidJSON: error.localizedDescription,
                parserError: error,
                originalInput: input,
                context: context
            )
        }
        print("[Lumina][StepGenerator] model.generateJSON returned, length: \(json.count)")
        do {
            return try LuminaReActStepParser.parse(json: json, availableTools: context.availableTools)
        } catch {
            print("[Lumina][StepGenerator] Parser failed: \(error.localizedDescription), triggering repair...")
            return try await repairAndParse(invalidJSON: json, parserError: error, originalInput: input, context: context)
        }
    }

    private func repairAndParse(
        invalidJSON: String,
        parserError: Error,
        originalInput: LuminaStructuredStepGenerationInput,
        context: LuminaReActStepContext
    ) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        var currentInvalidJSON = invalidJSON
        var currentParserError = parserError.localizedDescription
        let isEvaluation = Self.isEvaluation(context)
        for attempt in 1...1 {
            let repairError = isEvaluation ? Self.safeXMLRepairError(currentParserError) : currentParserError
            let repairInvalidOutput = isEvaluation ? "omitted forbidden XML/prose output" : currentInvalidJSON
            let repairPrompt = isEvaluation
                ? LuminaReActSchema.xmlRepairPrompt(
                    invalidOutput: repairInvalidOutput,
                    parserError: repairError,
                    availableToolNames: context.availableTools.map(\.name),
                    originalPrompt: originalInput.prompt,
                    task: context.request.text,
                    lastObservation: Self.latestObservationSummary(context)
                )
                : LuminaReActSchema.repairPrompt(
                    invalidJSON: currentInvalidJSON,
                    parserError: currentParserError,
                    availableToolNames: context.availableTools.map(\.name),
                    originalPrompt: originalInput.prompt,
                    task: context.request.text,
                    lastObservation: Self.latestObservationSummary(context)
                )
            context.progressSink?(LuminaStepGenerationProgress(
                requestID: context.request.id,
                iteration: context.iteration,
                elapsedMilliseconds: 0,
                message: "format_retry",
                partialOutput: "attempt=\(attempt)"
            ))
            let repairedJSON = try await generateJSON(input: LuminaStructuredStepGenerationInput(
                prompt: repairPrompt,
                content: originalInput.content,
                availableTools: originalInput.availableTools,
                maxOutputTokensHint: Self.outputBudgetHint(for: context, repairAttempt: attempt)
            ), context: context)
            Self.debugLog("Repaired model JSON attempt \(attempt): \(repairedJSON.prefix(1_200))")
            do {
                return try LuminaReActStepParser.parse(json: repairedJSON, availableTools: context.availableTools)
            } catch {
                currentInvalidJSON = repairedJSON
                currentParserError = error.localizedDescription
            }
        }
        throw LuminaReActParserError.invalidSchema("model did not produce valid standard ReAct JSON after repair: \(currentParserError)")
    }

    private func generateJSON(
        input: LuminaStructuredStepGenerationInput,
        context: LuminaReActStepContext
    ) async throws -> String {
        let progressSink = context.progressSink
        let startedAt = ContinuousClock.now
        let progressMapper: @Sendable (LuminaStructuredInferenceProgress) -> Void = { progress in
            progressSink?(LuminaStepGenerationProgress(
                requestID: context.request.id,
                iteration: context.iteration,
                elapsedMilliseconds: progress.elapsedMilliseconds,
                message: progress.phase,
                promptTokens: progress.promptTokens,
                sampledTokens: progress.sampledTokens,
                outputTokens: progress.outputTokens,
                partialOutput: progress.partialOutput
            ))
        }
        if let streaming = model as? any LuminaLocalStreamingMultimodalStructuredInferenceModel {
            return try await streaming.generateJSON(input: input, progress: progressMapper)
        }
        progressSink?(LuminaStepGenerationProgress(
            requestID: context.request.id,
            iteration: context.iteration,
            elapsedMilliseconds: Self.milliseconds(since: startedAt),
            message: "模型不支持 token 级进度，等待结构化输出完成"
        ))
        return try await model.generateJSON(input: input)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func outputBudgetHint(
        for context: LuminaReActStepContext,
        repairAttempt: Int?
    ) -> Int {
        let isEvaluation = Self.isEvaluation(context)
        if repairAttempt != nil {
            return isEvaluation ? 192 : 384
        }
        if context.availableTools.isEmpty {
            return isEvaluation ? 192 : 1_024
        }
        if context.remainingToolCalls <= 0 {
            return isEvaluation ? 192 : 768
        }
        let observations = context.trace.steps.compactMap(\.observation)
        let lastStep = context.trace.steps.last?.kind
        if lastStep == .observation {
            let latestObservation = observations.last
            if latestObservation?.status == .failed {
                return isEvaluation ? 192 : 384
            }
            if observations.count <= 1 {
                return isEvaluation ? 192 : 256
            }
            return isEvaluation ? 224 : 512
        }
        if !observations.isEmpty {
            return isEvaluation ? 224 : 512
        }
        if isEvaluation {
            return 224
        }
        if context.request.text.count > 1_200 || context.availableTools.count > 24 {
            return 384
        }
        return 192
    }

    private static func isEvaluation(_ context: LuminaReActStepContext) -> Bool {
        context.request.metadata.bool("lumina.evaluation.memory_access_disabled") == true ||
            context.request.metadata.bool("lumina.evaluation.ask_user_disabled") == true
    }

    private static func latestObservationSummary(_ context: LuminaReActStepContext) -> String {
        guard let observation = context.trace.steps.last?.observation else { return "" }
        var parts = [
            "toolName=\(observation.toolName)",
            "status=\(observation.status.rawValue)",
            "replayed=\(observation.replayed)",
            "summary=\(observation.summary)"
        ]
        if let error = observation.errorMessage, !error.isEmpty {
            parts.append("error=\(error)")
        }
        return parts.joined(separator: "; ")
    }

    private static func safeXMLRepairError(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("<observation") || lowered.contains("observation") {
            return "Forbidden runtime-owned observation tag appeared in model output."
        }
        if lowered.contains("<think") || lowered.contains("think") {
            return "Forbidden private thinking tag appeared in model output."
        }
        if lowered.contains("tool_use") && lowered.contains("closing") {
            return "tool_use XML was incomplete or malformed."
        }
        if lowered.contains("missing required parameter") {
            return "Tool parameters were missing required keys."
        }
        if lowered.contains("schema") {
            return "Output did not match the required ReAct schema."
        }
        return "Output was not exactly one valid Lumina XML ReAct step."
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Lumina][ReActModel] \(message)")
        #endif
    }
}
