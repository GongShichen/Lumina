import XCTest
@testable import LuminaAgentRuntimeApple

final class ValidationRecoveryStatusTests: XCTestCase {
    func testTrustedValidationFailureThenImplicitCorrectionSucceedsAndKeepsFailureHistory() async {
        let model = ValidationStatusModel(calls: [call(title: "invalid"), call(title: "corrected")])
        let runtime = LuminaAgentRuntime(tools: [validationTool()], stepGenerator: model,
                                         configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create the requested record."))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
        XCTAssertEqual(result.reactTrace?.observations.map(\.status), [.failed, .succeeded])
        XCTAssertTrue(result.toolResults.first?.errorMessage?.contains("No write occurred") == true)
    }

    func testTrustedValidationFailureThenCorrectionResolvesEachSupportedExplicitCallerKey() async {
        for keyName in ["idempotency_key", "instance_id", "client_request_id"] {
            let model = ValidationStatusModel(calls: [
                call(title: "invalid", keyName: keyName, key: "requested-operation"),
                call(title: "corrected", keyName: keyName, key: "requested-operation")
            ])
            let runtime = LuminaAgentRuntime(tools: [validationTool()], stepGenerator: model,
                                             configuration: luminaTestRuntimeConfiguration)

            let result = await runtime.run(request: LuminaAgentRequest(text: "Create the requested record."))

            XCTAssertEqual(result.status, .succeeded, "Correction did not resolve \(keyName)")
            XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded], keyName)
        }
    }

    func testHookValidationRejectionThenCorrectedToolSuccessResolvesRun() async {
        let executions = ValidationStatusCounter()
        let tool = AnyLuminaAgentTool(schema: schema()) { _, _ in
            await executions.increment()
            return LuminaToolResult(callID: UUID(), toolName: "record.create", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(
            tools: [tool], stepGenerator: ValidationStatusModel(calls: [call(title: "invalid"), call(title: "corrected")]),
            configuration: luminaTestRuntimeConfiguration, hooks: [ValidationStatusRejectingHook()]
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create the requested record."))
        let count = await executions.count

        XCTAssertEqual(count, 1)
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
        XCTAssertNotNil(result.reactTrace?.observations.first?.output["failure"])
    }

    func testSuccessForDifferentExplicitCallerKeyDoesNotResolvePriorValidationFailure() async {
        let model = ValidationStatusModel(calls: [
            call(title: "invalid", keyName: "instance_id", key: "first-operation"),
            call(title: "corrected", keyName: "instance_id", key: "second-operation")
        ])
        let runtime = LuminaAgentRuntime(tools: [validationTool()], stepGenerator: model,
                                         configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create the two requested records."))

        XCTAssertEqual(result.status, .partiallySucceeded)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
    }

    func testSuccessForDifferentToolDoesNotResolvePriorValidationFailure() async {
        let otherTool = AnyLuminaAgentTool(schema: schema(name: "record.archive")) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "record.archive", status: .succeeded)
        }
        let model = ValidationStatusModel(calls: [call(title: "invalid"), call(name: "record.archive", title: "corrected")])
        let runtime = LuminaAgentRuntime(tools: [validationTool(), otherTool], stepGenerator: model,
                                         configuration: luminaTestRuntimeConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create one record and archive another."))

        XCTAssertEqual(result.status, .partiallySucceeded)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
    }

    func testUnmarkedExecutionFailureIsNotErasedByLaterSuccess() async {
        let runtime = LuminaAgentRuntime(
            tools: [validationTool(trusted: false, idempotencyPolicy: "always_execute")],
            stepGenerator: ValidationStatusModel(calls: [call(title: "invalid"), call(title: "corrected")]),
            configuration: luminaTestRuntimeConfiguration
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "Run both specified mock operations."))

        XCTAssertEqual(result.status, .partiallySucceeded)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
    }

    func testDeniedAndCancelledResultsCannotBeClearedBySuccessOrValidationMarker() async {
        for failureStatus in [LuminaToolResultStatus.denied, .cancelled] {
            let runtime = LuminaAgentRuntime(
                tools: [validationTool(status: failureStatus, trusted: true, idempotencyPolicy: "always_execute")],
                stepGenerator: ValidationStatusModel(calls: [call(title: "invalid"), call(title: "corrected")]),
                configuration: luminaTestRuntimeConfiguration
            )

            let result = await runtime.run(request: LuminaAgentRequest(text: "Run both specified mock operations."))

            XCTAssertEqual(result.status, failureStatus == .cancelled ? .cancelled : .partiallySucceeded)
            XCTAssertEqual(result.toolResults.map(\.status), [failureStatus, .succeeded])
        }
    }

    private func call(name: String = "record.create", title: String,
                      keyName: String? = nil, key: String = "") -> LuminaToolCall {
        var arguments: [String: LuminaJSONValue] = ["title": .string(title)]
        if let keyName { arguments[keyName] = .string(key) }
        return LuminaToolCall(toolName: name, arguments: arguments)
    }

    private func schema(name: String = "record.create", idempotencyPolicy: String = "caller_keyed") -> LuminaToolSchema {
        LuminaToolSchema(name: name, description: "A mock record operation.", parameters: [
            LuminaToolParameterSchema(name: "title", type: .string, description: "Record title."),
            LuminaToolParameterSchema(name: "idempotency_key", type: .string, description: "Operation key.", required: false),
            LuminaToolParameterSchema(name: "instance_id", type: .string, description: "Operation instance.", required: false),
            LuminaToolParameterSchema(name: "client_request_id", type: .string, description: "Client request.", required: false)
        ], sideEffect: .appLocalWrite, idempotencyPolicy: idempotencyPolicy)
    }

    private func validationTool(status: LuminaToolResultStatus = .failed, trusted: Bool = true,
                                idempotencyPolicy: String = "caller_keyed") -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(schema: schema(idempotencyPolicy: idempotencyPolicy)) { arguments, _ in
            if arguments["title"] == .string("invalid") {
                return LuminaToolResult(
                    callID: UUID(), toolName: "record.create", status: status,
                    errorMessage: trusted ? "Invalid title. No write occurred." : "Execution failed; outcome unknown.",
                    validationFailed: trusted ? true : nil
                )
            }
            return LuminaToolResult(callID: UUID(), toolName: "record.create", status: .succeeded,
                                    output: ["id": .string("mock-created-record")])
        }
    }
}

private actor ValidationStatusModel: LuminaReActStepGenerator {
    private var calls: [LuminaToolCall]
    init(calls: [LuminaToolCall]) { self.calls = calls }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        guard !calls.isEmpty else { return .result("Finished the requested operations.") }
        return .action(thought: "Use the preceding observation.", call: calls.removeFirst())
    }
}

private actor ValidationStatusCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private struct ValidationStatusRejectingHook: LuminaAgentRuntimeHook {
    func handle(event: LuminaAgentRuntimeHookEvent,
                context: LuminaAgentRuntimeHookContext) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .beforeTool, context.toolCall?.toolName == "record.create",
              context.toolCall?.arguments["title"] == .string("invalid") else { return [] }
        return [.rejectToolCallForValidation(reason: "A required precondition is missing; no write occurred.", failure: [
            "code": .string("missing_precondition"),
            "reason": .string("Correct the missing precondition before writing."),
            "toolName": .string("record.create"),
            "retryPolicy": .string("correct_arguments")
        ])]
    }
}
