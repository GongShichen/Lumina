import AgentRuntime
import Foundation

public struct LuminaModelBackedReActPlanner: LuminaReActPlanner {
    private let model: any LuminaLocalMultimodalStructuredInferenceModel
    private let promptBuilder: LuminaReActPromptBuilder

    public init(
        multimodalModel: any LuminaLocalMultimodalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActPlanner = LuminaNoOpReActPlanner()
    ) {
        self.model = multimodalModel
        self.promptBuilder = promptBuilder
    }

    public init(
        model: any LuminaLocalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActPlanner = LuminaNoOpReActPlanner()
    ) {
        self.init(
            multimodalModel: LuminaTextOnlyStructuredModelAdapter(model),
            promptBuilder: promptBuilder,
            fallback: fallback
        )
    }

    public func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        let prompt = try await promptBuilder(context)
        Self.debugLog("Prompt characters: \(prompt.count), tools: \(context.availableTools.map(\.name).sorted().joined(separator: ", "))")
        let input = LuminaStructuredPlannerModelInput(
            prompt: prompt,
            content: context.request.content,
            availableTools: context.availableTools
        )
        let json = try await model.generateJSON(input: input)
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
        originalInput: LuminaStructuredPlannerModelInput,
        context: LuminaReActPlannerContext
    ) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        let repairPrompt = LuminaReActSchema.repairPrompt(
            invalidJSON: invalidJSON,
            parserError: parserError.localizedDescription,
            availableToolNames: context.availableTools.map(\.name),
            originalPrompt: originalInput.prompt
        )
        let repairedJSON = try await model.generateJSON(input: LuminaStructuredPlannerModelInput(
            prompt: repairPrompt,
            content: originalInput.content,
            availableTools: originalInput.availableTools
        ))
        Self.debugLog("Repaired model JSON: \(repairedJSON.prefix(1_200))")
        return try LuminaReActStepParser.parse(json: repairedJSON, availableTools: context.availableTools)
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Lumina][ReActPlanner] \(message)")
        #endif
    }
}
