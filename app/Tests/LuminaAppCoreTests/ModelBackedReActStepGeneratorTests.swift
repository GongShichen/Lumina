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

    func testModelBackedReActModelRetriesGenerationNormalizationOnceInEvaluation() async throws {
        let model = FailingThenValidMultimodalModel()
        let stepGenerator = LuminaModelBackedReActStepGenerator(multimodalModel: model) { _ in
            "FIRST BYTES MUST BE <thought>."
        }
        let schema = LuminaToolSchema(
            name: "device.current_time",
            description: "Current time",
            parameters: [],
            sideEffect: .readOnly
        )

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "现在几点",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: LuminaReActTrace(),
            iteration: 0,
            remainingToolCalls: 6,
            maximumObservationCharacters: 2_000
        ))

        let inputs = await model.inputs()
        XCTAssertEqual(inputs.count, 2)
        XCTAssertEqual(inputs.first?.maxOutputTokensHint, 224)
        XCTAssertEqual(inputs.last?.maxOutputTokensHint, 192)
        XCTAssertTrue(inputs.last?.prompt.contains("Repair the previous model response into exactly one valid Lumina XML ReAct step") == true)
        XCTAssertEqual(step.action?.toolName, "device.current_time")
    }

    func testEvaluationConvergenceTurnsRepeatedSuccessfulReadIntoResult() async throws {
        let model = MockStructuredInferenceModel(json: """
        {
          "type": "tool_use",
          "thought": "Read current time again",
          "tool_name": "device.current_time",
          "parameters": {},
          "requires_confirmation": false
        }
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "device.current_time",
            description: "Current time",
            parameters: [],
            sideEffect: .readOnly
        )
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Need time", call: LuminaToolCall(toolName: "device.current_time", arguments: [:])),
            .observation(LuminaReActObservation(
                toolName: "device.current_time",
                status: .succeeded,
                summary: "现在是 2026-06-02 20:10:00 Asia/Shanghai。"
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "现在几点？",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: trace,
            iteration: 1,
            remainingToolCalls: 5,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .result)
        XCTAssertNil(step.action)
        XCTAssertEqual(step.resultMarkdown, "现在是 2026-06-02 20:10:00 Asia/Shanghai。")
    }

    func testEvaluationRepairsMissingFileSaveNoteBodyFromGoal() async throws {
        let model = MockStructuredInferenceModel(json: """
        {
          "type": "tool_use",
          "thought": "Save note",
          "tool_name": "file.save_note",
          "parameters": {"filename": "lumina-test-benchmark.md", "title": "LuminaTest benchmark"},
          "requires_confirmation": true
        }
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "file.save_note",
            description: "Save note",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "Title"),
                LuminaToolParameterSchema(name: "filename", type: .string, description: "Filename"),
                LuminaToolParameterSchema(name: "body", type: .string, description: "Body")
            ],
            sideEffect: .appLocalWrite
        )

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "把 LuminaTest benchmark 运行说明保存成 Markdown 笔记",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: LuminaReActTrace(),
            iteration: 0,
            remainingToolCalls: 6,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "file.save_note")
        XCTAssertEqual(step.action?.arguments["filename"], .string("lumina-test-benchmark.md"))
        XCTAssertEqual(step.action?.arguments["title"], .string("LuminaTest benchmark"))
        XCTAssertTrue(step.action?.arguments["body"]?.stringValue?.contains("LuminaTest benchmark 运行说明") == true)
    }

    func testEvaluationConvergenceAllowsDifferentToolForMultiStepReadTask() async throws {
        let model = MockStructuredInferenceModel(json: """
        {
          "type": "tool_use",
          "thought": "Summarize clipboard content",
          "tool_name": "text.transform",
          "parameters": {"text": "LuminaTest benchmark clipboard content", "operation": "summary"},
          "requires_confirmation": false
        }
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schemas = [
            LuminaToolSchema(name: "clipboard.read", description: "Read clipboard", parameters: [], sideEffect: .readOnly),
            LuminaToolSchema(
                name: "text.transform",
                description: "Transform text",
                parameters: [
                    LuminaToolParameterSchema(name: "text", type: .string, description: "Text"),
                    LuminaToolParameterSchema(name: "operation", type: .string, description: "Operation")
                ],
                sideEffect: .readOnly
            )
        ]
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Need clipboard", call: LuminaToolCall(toolName: "clipboard.read", arguments: [:])),
            .observation(LuminaReActObservation(
                toolName: "clipboard.read",
                status: .succeeded,
                summary: "剪贴板内容：LuminaTest benchmark clipboard content"
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "读取 LuminaTest benchmark 的剪贴板内容并整理摘要",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: schemas,
            trace: trace,
            iteration: 1,
            remainingToolCalls: 5,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "text.transform")
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

private enum TestGenerationError: LocalizedError {
    case invalidXML

    var errorDescription: String? {
        "model did not produce valid XML"
    }
}

private actor FailingThenValidMultimodalModel: LuminaLocalMultimodalStructuredInferenceModel {
    private var capturedInputs: [LuminaStructuredStepGenerationInput] = []

    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        capturedInputs.append(input)
        if capturedInputs.count == 1 {
            throw TestGenerationError.invalidXML
        }
        return """
        {
          "type": "tool_use",
          "thought": "Read current time",
          "tool_name": "device.current_time",
          "parameters": {},
          "requires_confirmation": false
        }
        """
    }

    func inputs() -> [LuminaStructuredStepGenerationInput] {
        capturedInputs
    }
}
