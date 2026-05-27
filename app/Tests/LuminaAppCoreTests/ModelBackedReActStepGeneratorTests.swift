import LuminaAgentRuntime
import LuminaModelRuntime
import XCTest

final class ModelBackedReActStepGeneratorTests: XCTestCase {
    func testModelBackedReActModelParsesActionStep() async throws {
        let model = MockStructuredInferenceModel(json: """
        {
          "type": "tool_use",
          "thought": "Search first",
          "tool_name": "local.search",
          "parameters": {"query": "coffee", "limit": 3},
          "requires_confirmation": false
        }
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "local.search",
            description: "Search",
            parameters: [],
            sideEffect: .readOnly
        )

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(text: "coffee"),
            availableTools: [schema],
            trace: LuminaReActTrace(),
            iteration: 0,
            remainingToolCalls: 6,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.thought, "Search first")
        XCTAssertEqual(step.action?.toolName, "local.search")
        XCTAssertEqual(step.action?.arguments["query"], .string("coffee"))
    }

    func testModelBackedReActModelPassesMultimodalContentToModel() async throws {
        let model = CapturingMultimodalModel()
        let stepGenerator = LuminaModelBackedReActStepGenerator(multimodalModel: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "receipt.scan",
            description: "Scan receipt",
            parameters: [],
            sideEffect: .readOnly,
            acceptedInputModalities: [.image],
            outputModalities: [.structuredData]
        )
        let request = LuminaAgentRequest(content: [
            .text("识别小票"),
            .image(LuminaAgentMediaAsset(location: .fileURL("/tmp/receipt.jpg"), mimeType: "image/jpeg", summary: "receipt"))
        ])

        _ = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: request,
            availableTools: [schema],
            trace: LuminaReActTrace(),
            iteration: 0,
            remainingToolCalls: 6,
            maximumObservationCharacters: 2_000
        ))
        let captured = await model.capturedModalities()

        XCTAssertEqual(captured, [.text, .image])
    }
}

private struct MockStructuredInferenceModel: LuminaLocalStructuredInferenceModel {
    var json: String

    func generateJSON(prompt: String) async throws -> String {
        json
    }
}

private actor CapturingMultimodalModel: LuminaLocalMultimodalStructuredInferenceModel {
    private var modalities: Set<LuminaAgentModality> = []

    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        modalities = input.content.modalities
        return """
        {
          "type": "tool_use",
          "thought": "Scan receipt",
          "tool_name": "receipt.scan",
          "parameters": {},
          "requires_confirmation": false
        }
        """
    }

    func capturedModalities() -> Set<LuminaAgentModality> {
        modalities
    }
}
