import LuminaAgentRuntime
@testable import LuminaModelRuntime
import XCTest

final class ModelBackedReActStepGeneratorTests: XCTestCase {
    func testModelBackedReActModelParsesActionStep() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Search first</think>
        <tool_call>
        <function=local.search>
        <parameter=query>
        coffee
        </parameter>
        <parameter=limit>
        3
        </parameter>
        </function>
        </tool_call>
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

    func testModelBackedReActModelDoesNotRepairGenerationNormalizationFailureInEvaluation() async throws {
        let model = FailingThenValidMultimodalModel()
        let stepGenerator = LuminaModelBackedReActStepGenerator(multimodalModel: model) { _ in
            "Use MiniCPM-V4.6 <tool_call> transport."
        }
        let schema = LuminaToolSchema(
            name: "device.current_time",
            description: "Current time",
            parameters: [],
            sideEffect: .readOnly
        )

        do {
            _ = try await stepGenerator.nextStep(context: LuminaReActStepContext(
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
            XCTFail("Expected generation normalization failure to propagate without model repair.")
        } catch {
            XCTAssertEqual((error as? TestGenerationError), .invalidTransport)
        }

        let inputs = await model.inputs()
        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs.first?.maxOutputTokensHint, 224)
    }

    func testEvaluationPreservesRepeatedSuccessfulReadActionForRuntimeBudget() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Read current time again</think>
        <tool_call>
        <function=device.current_time>
        </function>
        </tool_call>
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

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "device.current_time")
    }

    func testEvaluationPreservesMissingFileSaveNoteBodyForToolObservation() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Save note</think>
        <tool_call>
        <function=file.save_note>
        <parameter=filename>
        lumina-test-benchmark.md
        </parameter>
        <parameter=title>
        LuminaTest benchmark
        </parameter>
        </function>
        </tool_call>
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
        XCTAssertNil(step.action?.arguments["body"])
    }

    func testEvaluationPreservesDifferentToolForMultiStepReadTask() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Summarize clipboard content</think>
        <tool_call>
        <function=text.transform>
        <parameter=operation>
        summary
        </parameter>
        <parameter=text>
        LuminaTest benchmark clipboard content
        </parameter>
        </function>
        </tool_call>
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

    func testEvaluationPreservesInvalidPostSuccessToolForRuntimeObservation() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Need final summary</think>
        <tool_call>
        <function=summary>
        <parameter=text>
        done
        </parameter>
        </function>
        </tool_call>
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "calendar.update",
            description: "Update calendar",
            parameters: [],
            sideEffect: .appLocalWrite
        )
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Update event", call: LuminaToolCall(toolName: "calendar.update", arguments: [:])),
            .observation(LuminaReActObservation(
                toolName: "calendar.update",
                status: .succeeded,
                summary: "用户已确认执行该工具。\n实际执行工具 calendar.update，实际执行参数 {\"id\":\"event-1\",\"startDateISO\":\"2026-06-08T07:30:00+08:00\",\"endDateISO\":\"2026-06-08T08:00:00+08:00\"}。最终回答必须使用这些实际执行参数和工具输出。\n日程已更新。"
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "把 LuminaTest 明天 7 点的日程改成 7 点半",
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

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "summary")
        XCTAssertEqual(step.action?.arguments["text"]?.stringValue, "done")
    }

    func testEvaluationDoesNotAutoCompleteAfterSuccessfulTerminalTool() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Search again</think>
        <tool_call>
        <function=calendar.search>
        <parameter=query>
        LuminaTest
        </parameter>
        </function>
        </tool_call>
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schemas = [
            LuminaToolSchema(name: "calendar.search", description: "Search calendar", parameters: [], sideEffect: .readOnly),
            LuminaToolSchema(name: "calendar.update", description: "Update calendar", parameters: [], sideEffect: .appLocalWrite)
        ]
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Update event", call: LuminaToolCall(toolName: "calendar.update", arguments: [
                "id": .string("LuminaTest-001"),
                "startDateISO": .string("2026-06-08T07:30:00+08:00")
            ])),
            .observation(LuminaReActObservation(
                toolName: "calendar.update",
                status: .succeeded,
                summary: "用户已确认执行该工具。\n实际执行工具 calendar.update，实际执行参数 {\"id\":\"LuminaTest-001\",\"startDateISO\":\"2026-06-08T07:30:00+08:00\",\"endDateISO\":\"2026-06-08T08:00:00+08:00\"}。最终回答必须使用这些实际执行参数和工具输出。\n日程已更新：LuminaTest 项目同步"
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "把 LuminaTest 明天 7 点的日程改成 7 点半",
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
        XCTAssertEqual(step.action?.toolName, "calendar.search")
        XCTAssertEqual(step.action?.arguments["query"]?.stringValue, "LuminaTest")
    }

    func testEvaluationPreservesTextSummarizeToolNameForRuntimeObservation() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Summarize the text</think>
        <tool_call>
        <function=text.summarize>
        <parameter=operation>
        summary
        </parameter>
        <parameter=text>
        LuminaTest report
        </parameter>
        </function>
        </tool_call>
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "text.transform",
            description: "Transform text",
            parameters: [
                LuminaToolParameterSchema(name: "text", type: .string, description: "Text"),
                LuminaToolParameterSchema(name: "mode", type: .string, description: "Mode", required: false)
            ],
            sideEffect: .readOnly
        )

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "读取 LuminaTest-report.md 并整理摘要",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: LuminaReActTrace(),
            iteration: 1,
            remainingToolCalls: 5,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "text.summarize")
        XCTAssertEqual(step.action?.arguments["operation"]?.stringValue, "summary")
    }

    func testEvaluationPreservesWriteAfterTextTransformForRuntimeObservation() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Write final answer</think>
        <tool_call>
        <function=write>
        <parameter=text>
        Example Domain
        </parameter>
        </function>
        </tool_call>
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "text.transform",
            description: "Transform text",
            parameters: [],
            sideEffect: .readOnly
        )
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Summarize", call: LuminaToolCall(toolName: "text.transform", arguments: ["text": .string("Example Domain")])),
            .observation(LuminaReActObservation(
                toolName: "text.transform",
                status: .succeeded,
                summary: "实际执行工具 text.transform，实际执行参数 {\"text\":\"Example Domain\"}。最终回答必须使用这些实际执行参数和工具输出。\n文本已整理。"
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "抓取 https://example.com 的正文并整理成 3 条摘要",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: trace,
            iteration: 2,
            remainingToolCalls: 4,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "write")
        XCTAssertEqual(step.action?.arguments["text"]?.stringValue, "Example Domain")
    }

    func testEvaluationPreservesInvalidToolAfterReplayedReadObservation() async throws {
        let model = MockStructuredInferenceModel(json: """
        <think>Summarize ledger search results</think>
        <tool_call>
        <function=summarize_ledger>
        <parameter=amounts>
        [42.0]
        </parameter>
        </function>
        </tool_call>
        """)
        let stepGenerator = LuminaModelBackedReActStepGenerator(model: model) { context in
            context.request.text
        }
        let schema = LuminaToolSchema(
            name: "ledger.search",
            description: "Search ledger",
            parameters: [],
            sideEffect: .readOnly
        )
        let trace = LuminaReActTrace(steps: [
            .action(thought: "Search ledger", call: LuminaToolCall(toolName: "ledger.search", arguments: ["query": .string("LuminaTest 咖啡")])),
            .observation(LuminaReActObservation(
                toolName: "ledger.search",
                status: .succeeded,
                summary: "[id=ledger-1] LuminaTest 咖啡: 42.0",
                replayed: true
            ))
        ])

        let step = try await stepGenerator.nextStep(context: LuminaReActStepContext(
            request: LuminaAgentRequest(
                text: "查最近的 LuminaTest 咖啡支出",
                metadata: [
                    "lumina.evaluation.memory_access_disabled": .bool(true),
                    "lumina.evaluation.ask_user_disabled": .bool(true)
                ]
            ),
            availableTools: [schema],
            trace: trace,
            iteration: 2,
            remainingToolCalls: 4,
            maximumObservationCharacters: 2_000
        ))

        XCTAssertEqual(step.kind, .action)
        XCTAssertEqual(step.action?.toolName, "summarize_ledger")
        if case let .array(amounts)? = step.action?.arguments["amounts"] {
            XCTAssertEqual(amounts.first?.numberValue, 42.0)
        } else {
            XCTFail("expected amounts array")
        }
    }

    func testMiniCPMV46ExtractorParsesCompleteThinkBlockBeforeToolCall() throws {
        let json = try LuminaMiniCPMV46ReActModel.extractJSONObject(from: """
        <think>Need current time.</think>
        <tool_call>
        <function=device.current_time>
        </function>
        </tool_call>
        """)

        XCTAssertTrue(json.contains(#""type":"tool_use""#))
        XCTAssertTrue(json.contains(#""tool_name":"device.current_time""#))
        XCTAssertTrue(json.contains(#""parameters":{}"#))
    }

    func testMiniCPMV46ExtractorDoesNotParseLegacyToolUseAsAction() throws {
        let json = try LuminaMiniCPMV46ReActModel.extractJSONObject(from: """
        <tool_use name="device.current_time" requires_confirmation="false">{}</tool_use>
        """)

        XCTAssertTrue(json.contains(#""type":"result""#))
        XCTAssertFalse(json.contains(#""tool_name":"device.current_time""#))
    }
}

private struct MockStructuredInferenceModel: LuminaLocalStructuredInferenceModel {
    var json: String

    func generateJSON(prompt: String) async throws -> String {
        guard let normalized = LuminaReActTransport.normalizeMiniCPMV46ToolCalls(from: json) else {
            throw TestGenerationError.invalidTransport
        }
        return normalized
    }
}

private actor CapturingMultimodalModel: LuminaLocalMultimodalStructuredInferenceModel {
    private var modalities: Set<LuminaAgentModality> = []

    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        modalities = input.content.modalities
        let output = """
        <think>Scan receipt</think>
        <tool_call>
        <function=receipt.scan>
        </function>
        </tool_call>
        """
        guard let normalized = LuminaReActTransport.normalizeMiniCPMV46ToolCalls(from: output) else {
            throw TestGenerationError.invalidTransport
        }
        return normalized
    }

    func capturedModalities() -> Set<LuminaAgentModality> {
        modalities
    }
}

private enum TestGenerationError: LocalizedError, Equatable {
    case invalidTransport

    var errorDescription: String? {
        "model output could not be normalized by MiniCPM transport extraction"
    }
}

private actor FailingThenValidMultimodalModel: LuminaLocalMultimodalStructuredInferenceModel {
    private var capturedInputs: [LuminaStructuredStepGenerationInput] = []

    func generateJSON(input: LuminaStructuredStepGenerationInput) async throws -> String {
        capturedInputs.append(input)
        if capturedInputs.count == 1 {
            throw TestGenerationError.invalidTransport
        }
        let output = """
        <think>Read current time</think>
        <tool_call>
        <function=device.current_time>
        </function>
        </tool_call>
        """
        guard let normalized = LuminaReActTransport.normalizeMiniCPMV46ToolCalls(from: output) else {
            throw TestGenerationError.invalidTransport
        }
        return normalized
    }

    func inputs() -> [LuminaStructuredStepGenerationInput] {
        capturedInputs
    }
}
