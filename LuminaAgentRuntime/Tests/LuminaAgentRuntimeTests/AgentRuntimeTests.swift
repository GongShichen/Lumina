import XCTest
@testable import LuminaAgentRuntimeApple

final class LuminaAgentRuntimeTests: XCTestCase {
    func testToolSchemaRoundTrip() throws {
        let schema = LuminaToolSchema(
            name: "message.compose",
            description: "Compose a message.",
            parameters: [
                LuminaToolParameterSchema(name: "body", type: .string, description: "Body", sensitive: true)
            ],
            sideEffect: .externalCommunication,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .image],
            outputModalities: [.text]
        )

        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(LuminaToolSchema.self, from: data)
        XCTAssertEqual(decoded, schema)
    }

    func testAgentRequestSupportsMultimodalContent() throws {
        let image = LuminaAgentMediaAsset(
            location: .fileURL("/tmp/receipt.jpg"),
            mimeType: "image/jpeg",
            filename: "receipt.jpg",
            width: 1024,
            height: 768,
            summary: "coffee receipt"
        )
        let request = LuminaAgentRequest(content: [
            .text("帮我记账"),
            .image(image),
            .json(.object(["source": .string("camera")]))
        ])

        XCTAssertTrue(request.text.contains("帮我记账"))
        XCTAssertTrue(request.text.contains("coffee receipt"))
        XCTAssertEqual(request.content.modalities, [.text, .image, .structuredData])

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(LuminaAgentRequest.self, from: data)
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
        let part = LuminaAgentContentPart.markdown(markdown)

        XCTAssertEqual(part.modality, .text)
        XCTAssertEqual(part.textForModelInput, markdown)

        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(LuminaAgentContentPart.self, from: data)

        XCTAssertEqual(decoded, part)
    }

    func testPermissionGateRequiresConfirmationForWrites() async {
        let gate = LuminaDefaultPermissionGate()
        let schema = LuminaToolSchema(
            name: "reminder.create",
            description: "Create reminder",
            parameters: [],
            sideEffect: .systemWrite
        )
        let call = LuminaToolCall(toolName: schema.name, arguments: [:])
        let decision = await gate.decision(for: call, schema: schema, request: LuminaAgentRequest(text: "提醒我"))

        guard case .requiresConfirmation = decision else {
            XCTFail("Expected confirmation decision")
            return
        }
    }

    func testAuditRedactsSensitiveArguments() {
        let schema = LuminaToolSchema(
            name: "message.compose",
            description: "Compose message",
            parameters: [
                LuminaToolParameterSchema(name: "body", type: .string, description: "Body", sensitive: true)
            ],
            sideEffect: .externalCommunication
        )

        let redacted = LuminaAuditRedactor.redact(arguments: ["body": .string("secret"), "topic": .string("lunch")], schema: schema)
        XCTAssertEqual(redacted["body"], .string("<redacted>"))
        XCTAssertEqual(redacted["topic"], .string("lunch"))
    }

    func testJSONLAuditLoggerReadsRecentRecords() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-audit-\(UUID().uuidString)", isDirectory: true)
        let logger = LuminaJSONLAuditLogger(url: directory.appendingPathComponent("audit.jsonl"))
        let requestID = UUID()

        await logger.append(LuminaAuditRecord(
            requestID: requestID,
            toolName: "local.search",
            schemaVersion: 1,
            arguments: ["query": .string("memory")],
            permission: "allowed",
            confirmed: false,
            resultStatus: .succeeded,
            outputSummary: "first"
        ))
        await logger.append(LuminaAuditRecord(
            requestID: requestID,
            toolName: "ledger.record",
            schemaVersion: 1,
            arguments: ["memo": .string("<redacted>")],
            permission: "confirmed",
            confirmed: true,
            resultStatus: .succeeded,
            outputSummary: "second"
        ))

        let recent = await logger.recentRecords(limit: 1)

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.toolName, "ledger.record")
        try? FileManager.default.removeItem(at: directory)
    }

    func testRuntimeRunsReadOnlyTool() async {
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "local.search",
                description: "Search",
                parameters: [LuminaToolParameterSchema(name: "query", type: .string, description: "Query")],
                sideEffect: .readOnly,
                outputModalities: [.text, .structuredData]
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                output: ["query": arguments["query"] ?? .null],
                content: [.text("search finished")]
            )
        }

        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: FixedReActModel(calls: [
                LuminaToolCall(toolName: "local.search", arguments: ["query": .string("查本地数据")])
            ]),
            configuration: luminaTestRuntimeConfiguration
        )
        let result = await runtime.run(request: LuminaAgentRequest(text: "查本地数据"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.count, 1)
        XCTAssertEqual(result.toolResults.first?.toolName, "local.search")
        XCTAssertEqual(result.toolResults.first?.content.first?.modality, .text)
    }

    func testRuntimeDeniesWhenConfirmationRejected() async {
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "ledger.record",
                description: "Ledger",
                parameters: [LuminaToolParameterSchema(name: "memo", type: .string, description: "Memo")],
                sideEffect: .appLocalWrite
            )
        ) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "ledger.record", status: .succeeded)
        }

        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: FixedReActModel(calls: [
                LuminaToolCall(toolName: "ledger.record", arguments: ["memo": .string("咖啡 42 元")], requiresConfirmation: true)
            ]),
            configuration: luminaTestRuntimeConfiguration,
            confirmationCoordinator: LuminaDenyAllConfirmationCoordinator()
        )
        let result = await runtime.run(request: LuminaAgentRequest(text: "记账 咖啡 42 元"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.toolResults.first?.status, .denied)
    }

    func testRuntimeObservationIncludesAcceptedConfirmationFeedback() async {
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "ledger.record",
                description: "Ledger",
                parameters: [LuminaToolParameterSchema(name: "memo", type: .string, description: "Memo")],
                sideEffect: .appLocalWrite
            )
        ) { _, _ in
            LuminaToolResult(
                callID: UUID(),
                toolName: "ledger.record",
                status: .succeeded,
                content: [.text("账目已写入。")]
            )
        }

        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: FixedReActModel(calls: [
                LuminaToolCall(toolName: "ledger.record", arguments: ["memo": .string("咖啡 42 元")], requiresConfirmation: true)
            ]),
            configuration: luminaTestRuntimeConfiguration,
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator()
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "记账 咖啡 42 元"))
        let observation = result.reactTrace?.observations.first?.summary ?? ""

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(observation.contains("用户已确认执行该工具"))
        XCTAssertTrue(observation.contains("账目已写入"))
    }

    func testRuntimeStreamEmitsEventsDuringExecution() async {
        let tool = AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "local.search",
                description: "Search",
                parameters: [],
                sideEffect: .readOnly
            )
        ) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "local.search", status: .succeeded)
        }

        let runtime = LuminaAgentRuntime(
            tools: [tool],
            stepGenerator: FixedReActModel(calls: [LuminaToolCall(toolName: "local.search", arguments: [:])]),
            configuration: luminaTestRuntimeConfiguration
        )
        var sawAction = false
        var sawToolStart = false
        var sawFinished = false

        for await event in runtime.runStream(request: LuminaAgentRequest(text: "查 coffee")) {
            switch event {
            case .actionProposed:
                sawAction = true
            case .toolStarted:
                sawToolStart = true
            case .finished(let result):
                sawFinished = result.timing.totalMilliseconds >= 0
            default:
                break
            }
        }

        XCTAssertTrue(sawAction)
        XCTAssertTrue(sawToolStart)
        XCTAssertTrue(sawFinished)
    }
}

private struct FixedReActModel: LuminaReActStepGenerator {
    var calls: [LuminaToolCall]

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        let index = context.trace.actionCount
        guard index < calls.count else { return .result("done") }
        return .action(thought: "Fixed ReAct test step", call: calls[index])
    }
}
