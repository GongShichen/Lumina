import XCTest
@testable import AgentRuntime

final class AgentRuntimeTests: XCTestCase {
    func testToolSchemaRoundTrip() throws {
        let schema = ToolSchema(
            name: "message.compose",
            description: "Compose a message.",
            parameters: [
                ToolParameterSchema(name: "body", type: .string, description: "Body", sensitive: true)
            ],
            sideEffect: .externalCommunication,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .image],
            outputModalities: [.text]
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(ToolSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testAgentRequestSupportsMultimodalContent() throws {
        let image = AgentMediaAsset(
            location: .fileURL("/tmp/receipt.jpg"),
            mimeType: "image/jpeg",
            filename: "receipt.jpg",
            width: 1024,
            height: 768,
            summary: "coffee receipt"
        )
        let request = AgentRequest(content: [
            .text("帮我记账"),
            .image(image),
            .json(.object(["source": .string("camera")]))
        ])

        XCTAssertTrue(request.text.contains("帮我记账"))
        XCTAssertTrue(request.text.contains("coffee receipt"))
        XCTAssertEqual(request.content.modalities, [.text, .image, .structuredData])

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AgentRequest.self, from: data)
        XCTAssertEqual(decoded.content.count, 3)
    }

    func testMarkdownContentRoundTripsAsTextModality() throws {
        let markdown = """
        ## 检索结果

        - 日历：10:00 产品评审
        - 提醒：提前 10 分钟

        | 来源 | 置信度 |
        | --- | --- |
        | Calendar | high |
        """
        let part = AgentContentPart.markdown(markdown)

        XCTAssertEqual(part.modality, .text)
        XCTAssertEqual(part.textForPlanning, markdown)

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(AgentContentPart.self, from: data)

        XCTAssertEqual(decoded, part)
    }

    func testPermissionGateRequiresConfirmationForWrites() async {
        let gate = DefaultPermissionGate()
        let schema = ToolSchema(
            name: "reminder.create",
            description: "Create reminder",
            parameters: [],
            sideEffect: .systemWrite
        )
        let call = ToolCall(toolName: schema.name, arguments: [:])
        let decision = await gate.decision(for: call, schema: schema, request: AgentRequest(text: "提醒我"))

        guard case .requiresConfirmation = decision else {
            XCTFail("Expected confirmation decision")
            return
        }
    }

    func testAuditRedactsSensitiveArguments() {
        let schema = ToolSchema(
            name: "message.compose",
            description: "Compose message",
            parameters: [
                ToolParameterSchema(name: "body", type: .string, description: "Body", sensitive: true)
            ],
            sideEffect: .externalCommunication
        )

        let redacted = AuditRedactor.redact(arguments: ["body": .string("secret"), "topic": .string("lunch")], schema: schema)
        XCTAssertEqual(redacted["body"], .string("<redacted>"))
        XCTAssertEqual(redacted["topic"], .string("lunch"))
    }

    func testRuntimeRunsReadOnlyTool() async {
        let tool = AnyAgentTool(
            schema: ToolSchema(
                name: "local.search",
                description: "Search",
                parameters: [ToolParameterSchema(name: "query", type: .string, description: "Query")],
                sideEffect: .readOnly,
                outputModalities: [.text, .structuredData]
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            return ToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                output: ["query": arguments["query"] ?? .null],
                content: [.text("search finished")]
            )
        }

        let runtime = AgentRuntime(tools: [tool], planner: RuleBasedPlanner())
        let result = await runtime.run(request: AgentRequest(text: "查本地数据"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.toolResults.first?.toolName, "local.search")
        XCTAssertEqual(result.toolResults.first?.content.first?.modality, .text)
    }

    func testRuntimeDeniesWhenConfirmationRejected() async {
        let tool = AnyAgentTool(
            schema: ToolSchema(
                name: "ledger.record",
                description: "Ledger",
                parameters: [ToolParameterSchema(name: "memo", type: .string, description: "Memo")],
                sideEffect: .appLocalWrite
            )
        ) { _, _ in
            ToolResult(callID: UUID(), toolName: "ledger.record", status: .succeeded)
        }

        let runtime = AgentRuntime(
            tools: [tool],
            planner: RuleBasedPlanner(),
            confirmationCoordinator: DenyAllConfirmationCoordinator()
        )
        let result = await runtime.run(request: AgentRequest(text: "记账 咖啡 42 元"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.toolResults.first?.status, .denied)
    }

    func testModelBackedPlannerParsesGenericJSONPlan() async throws {
        let model = MockStructuredInferenceModel(json: """
        {
          "summary": "Search first",
          "toolCalls": [
            {
              "toolName": "local.search",
              "arguments": {"query": "coffee", "limit": 3},
              "requiresConfirmation": false
            }
          ]
        }
        """)
        let planner = ModelBackedPlanner(model: model)
        let schema = ToolSchema(
            name: "local.search",
            description: "Search",
            parameters: [],
            sideEffect: .readOnly
        )

        let plan = try await planner.makePlan(for: AgentRequest(text: "coffee"), availableTools: [schema])

        XCTAssertEqual(plan.summary, "Search first")
        XCTAssertEqual(plan.toolCalls.first?.toolName, "local.search")
        XCTAssertEqual(plan.toolCalls.first?.arguments["query"], .string("coffee"))
    }

    func testModelBackedPlannerPassesMultimodalContentToModel() async throws {
        let model = CapturingMultimodalModel()
        let planner = ModelBackedPlanner(multimodalModel: model)
        let schema = ToolSchema(
            name: "receipt.scan",
            description: "Scan receipt",
            parameters: [],
            sideEffect: .readOnly,
            acceptedInputModalities: [.image],
            outputModalities: [.structuredData]
        )
        let request = AgentRequest(content: [
            .text("识别小票"),
            .image(AgentMediaAsset(location: .fileURL("/tmp/receipt.jpg"), mimeType: "image/jpeg", summary: "receipt"))
        ])

        _ = try await planner.makePlan(for: request, availableTools: [schema])
        let captured = await model.capturedModalities()

        XCTAssertEqual(captured, [.text, .image])
    }

    func testRuntimeStreamEmitsEventsDuringExecution() async {
        let tool = AnyAgentTool(
            schema: ToolSchema(
                name: "local.search",
                description: "Search",
                parameters: [],
                sideEffect: .readOnly
            )
        ) { _, _ in
            ToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }

        let runtime = AgentRuntime(tools: [tool], planner: RuleBasedPlanner())
        var sawPlan = false
        var sawToolStart = false
        var sawFinished = false

        for await event in runtime.runStream(request: AgentRequest(text: "查 coffee")) {
            switch event {
            case .planCreated:
                sawPlan = true
            case .toolStarted:
                sawToolStart = true
            case .finished(let result):
                sawFinished = result.timing.totalMilliseconds >= 0
            default:
                break
            }
        }

        XCTAssertTrue(sawPlan)
        XCTAssertTrue(sawToolStart)
        XCTAssertTrue(sawFinished)
    }
}

private struct MockStructuredInferenceModel: LocalStructuredInferenceModel {
    var json: String

    func generateJSON(prompt: String) async throws -> String {
        json
    }
}

private actor CapturingMultimodalModel: LocalMultimodalStructuredInferenceModel {
    private var modalities: Set<AgentModality> = []

    func generateJSON(input: StructuredPlannerModelInput) async throws -> String {
        modalities = input.content.modalities
        return """
        {
          "summary": "Scan receipt",
          "toolCalls": [
            {
              "toolName": "receipt.scan",
              "arguments": {},
              "requiresConfirmation": false
            }
          ]
        }
        """
    }

    func capturedModalities() -> Set<AgentModality> {
        modalities
    }
}
