import LuminaAgentClient
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
        let prompt = try await promptBuilder(context)
        Self.debugLog("Prompt characters: \(prompt.count), tools: \(context.availableTools.map(\.name).sorted().joined(separator: ", "))")
        let input = LuminaStructuredStepGenerationInput(
            prompt: prompt,
            content: context.request.content,
            availableTools: context.availableTools,
            maxOutputTokensHint: Self.outputBudgetHint(for: context, repairAttempt: nil)
        )
        let json = try await generateJSON(input: input, context: context)
        Self.debugLog("Model JSON: \(json.prefix(1_200))")
        do {
            return try LuminaReActStepParser.parse(json: json, availableTools: context.availableTools)
        } catch {
            Self.debugLog("Parser failed: \(error.localizedDescription)")
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
        for attempt in 1...2 {
            let repairPrompt = LuminaReActSchema.repairPrompt(
                invalidJSON: currentInvalidJSON,
                parserError: currentParserError,
                availableToolNames: context.availableTools.map(\.name),
                originalPrompt: originalInput.prompt
            )
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
        let isEvaluation = context.request.metadata.bool("lumina.evaluation.memory_access_disabled") == true ||
            context.request.metadata.bool("lumina.evaluation.ask_user_disabled") == true
        if repairAttempt != nil {
            return isEvaluation ? 64 : 384
        }
        if context.availableTools.isEmpty {
            return isEvaluation ? 64 : 1_024
        }
        if context.remainingToolCalls <= 0 {
            return isEvaluation ? 64 : 768
        }
        let observations = context.trace.steps.compactMap(\.observation)
        let lastStep = context.trace.steps.last?.kind
        if lastStep == .observation {
            let latestObservation = observations.last
            if latestObservation?.status == .failed {
                return isEvaluation ? 64 : 384
            }
            if observations.count <= 1 {
                return isEvaluation ? 64 : 256
            }
            return isEvaluation ? 64 : 512
        }
        if !observations.isEmpty {
            return isEvaluation ? 64 : 512
        }
        if isEvaluation {
            return 96
        }
        if context.request.text.count > 1_200 || context.availableTools.count > 24 {
            return 384
        }
        return 192
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Lumina][ReActModel] \(message)")
        #endif
    }
}
