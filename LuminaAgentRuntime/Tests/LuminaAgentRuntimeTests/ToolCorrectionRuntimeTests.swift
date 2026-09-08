import XCTest
@testable import LuminaAgentRuntimeApple

final class ToolCorrectionRuntimeTests: XCTestCase {
    func testNestedToolOutputReachesNextModelStepWithoutLosingJSONTypes() async throws {
        let output: [String: LuminaJSONValue] = [
            "time": .string("2026-09-08T23:45:00+08:00"),
            "timezone": .string("Asia/Shanghai"),
            "id": .string("record-from-tool-42"),
            "object": .object([
                "enabled": .bool(true),
                "count": .number(7),
                "fraction": .number(1.25),
                "missing": .null,
                "children": .array([.string("one"), .number(2), .bool(false), .null,
                                     .object(["id": .string("child-from-tool")])])
            ])
        ]
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.read", arguments: [:])])
        let tool = AnyLuminaAgentTool(schema: readSchema) { _, _ in
            LuminaToolResult(callID: UUID(), toolName: "record.read", status: .succeeded, output: output)
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Read the record."))
        let observations = await model.observations
        let observed = try XCTUnwrap(observations.last)

        XCTAssertEqual(observed.status, .succeeded)
        for (key, value) in output {
            XCTAssertEqual(observed.output[key], value, "Next model step lost or changed \(key)")
            XCTAssertEqual(result.toolResults.first?.output[key], value)
        }
    }

    func testHostFailureFeedbackReachesNextModelStepWithStructuredCorrection() async throws {
        let arguments: [String: LuminaJSONValue] = ["title": .string("Breakfast")]
        let failure: LuminaJSONValue = .object([
            "code": .string("validation_failed"),
            "reason": .string("dueDateISO cannot be earlier than the observed current time."),
            "toolName": .string("record.create"),
            "arguments": .object(arguments),
            "fieldErrors": .array([.object([
                "field": .string("dueDateISO"),
                "reason": .string("Use a future ISO timestamp derived from the current-time observation.")
            ])]),
            "missingInformation": .array([.string("current time and timezone")]),
            "suggestedCall": .object(["toolName": .string("device.current_time"), "arguments": .object([:])]),
            "retryPolicy": .string("prerequisite")
        ])
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.create", arguments: arguments)])
        let tool = AnyLuminaAgentTool(schema: writeSchema) { _, _ in
            LuminaToolResult(
                callID: UUID(), toolName: "record.create", status: .failed,
                output: ["failure": failure, "written": .bool(false)],
                errorMessage: "Original host validation error.", validationFailed: true
            )
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        _ = await runtime.run(request: LuminaAgentRequest(text: "Create a breakfast record."))
        let observations = await model.observations
        let observed = try XCTUnwrap(observations.last)

        XCTAssertEqual(observed.status, .failed)
        XCTAssertEqual(observed.output["failure"], failure)
        XCTAssertEqual(observed.output["written"], .bool(false))
        XCTAssertEqual(observed.errorMessage, "Original host validation error.")
    }

    func testCallerKeyedSchemaFailureAllowsCorrectedArgumentsToExecuteOnce() async {
        let executions = CorrectionExecutionLog()
        let tool = successfulWriteTool(executions: executions)
        let model = CorrectionRecordingModel(calls: [
            LuminaToolCall(toolName: "record.create", arguments: [:]),
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast")])
        ])
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create a breakfast record."))
        let calls = await executions.calls

        XCTAssertEqual(calls, [["title": .string("Breakfast")]])
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .succeeded])
        XCTAssertFalse(result.toolResults.last?.output["replayed"]?.boolValue == true)
    }

    func testValidationHookRejectsBeforeHostExecutionAndSuppliesPrerequisiteCallToModel() async throws {
        let executions = CorrectionExecutionLog()
        let arguments: [String: LuminaJSONValue] = ["title": .string("Breakfast")]
        let suggestedCall: LuminaJSONValue = .object([
            "toolName": .string("device.current_time"), "arguments": .object([:])
        ])
        let failure: [String: LuminaJSONValue] = [
            "code": .string("missing_current_time"),
            "reason": .string("A current-time observation is required before writing a relative date."),
            "toolName": .string("record.create"),
            "arguments": .object(arguments),
            "suggestedCall": suggestedCall,
            "retryPolicy": .string("prerequisite")
        ]
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.create", arguments: arguments)])
        let runtime = LuminaAgentRuntime(
            tools: [successfulWriteTool(executions: executions)], stepGenerator: model,
            configuration: correctionConfiguration, hooks: [CorrectionRejectingHook(failure: failure)]
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create a record tomorrow morning."))
        let observations = await model.observations
        let observed = try XCTUnwrap(observations.last)
        let calls = await executions.calls

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(result.toolResults.first?.status, .failed)
        XCTAssertEqual(observed.status, .failed)
        XCTAssertEqual(observed.output["failure"], .object(failure))
        XCTAssertEqual(try failureObject(in: observed)["suggestedCall"], suggestedCall)
    }

    func testCallerKeyedHostValidationFailureReplaysIdenticalArgumentsThenExecutesCorrection() async {
        let executions = CorrectionExecutionLog()
        let tool = AnyLuminaAgentTool(schema: writeSchema) { arguments, _ in
            await executions.record(arguments)
            if arguments["title"] == .string("invalid") {
                return LuminaToolResult(
                    callID: UUID(), toolName: "record.create", status: .failed,
                    errorMessage: "The title is invalid; no record was created.", validationFailed: true
                )
            }
            return LuminaToolResult(callID: UUID(), toolName: "record.create", status: .succeeded,
                                    output: ["id": .string("created-once")])
        }
        let model = CorrectionRecordingModel(calls: [
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("invalid")]),
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("invalid")]),
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast")])
        ])
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create a breakfast record."))
        let calls = await executions.calls
        let observations = await model.observations

        XCTAssertEqual(calls.map { $0["title"] }, [.string("invalid"), .string("Breakfast")])
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .failed, .succeeded])
        XCTAssertEqual(result.toolResults.filter { $0.output["replayed"]?.boolValue == true }.count, 1)
        XCTAssertEqual(result.toolResults.last?.output["id"], .string("created-once"))
        XCTAssertNotNil(observations.first?.output["failure"])
        XCTAssertEqual(observations.count, 3)
        if observations.count == 3 {
            XCTAssertTrue(observations[1].replayed)
            XCTAssertEqual(observations[1].output["failure"], observations[0].output["failure"])
            XCTAssertEqual(observations[1].errorMessage, observations[0].errorMessage)
        }
    }

    func testCallerKeyedUnmarkedFailureDoesNotReexecuteChangedArguments() async {
        let executions = CorrectionExecutionLog()
        let tool = AnyLuminaAgentTool(schema: writeSchema) { arguments, _ in
            await executions.record(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "record.create", status: .failed,
                                    errorMessage: "Connection lost; the write outcome is unknown.")
        }
        let model = CorrectionRecordingModel(calls: [
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast")]),
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast changed")])
        ])
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create one breakfast record."))
        let calls = await executions.calls

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.toolResults.map(\.status), [.failed, .failed])
        XCTAssertEqual(result.toolResults.last?.output["replayed"]?.boolValue, true)
    }

    func testCallerKeyedSuccessDoesNotRepeatWriteWhenArgumentsDrift() async {
        let executions = CorrectionExecutionLog()
        let model = CorrectionRecordingModel(calls: [
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast")]),
            LuminaToolCall(toolName: "record.create", arguments: ["title": .string("Breakfast changed")])
        ])
        let runtime = LuminaAgentRuntime(tools: [successfulWriteTool(executions: executions)],
                                         stepGenerator: model, configuration: correctionConfiguration)

        let result = await runtime.run(request: LuminaAgentRequest(text: "Create one breakfast record."))
        let calls = await executions.calls

        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(result.toolResults.map(\.status), [.succeeded, .succeeded])
        XCTAssertEqual(result.toolResults.last?.output["replayed"]?.boolValue, true)
    }

    func testUnknownToolFeedbackReachesModelWithActualArgumentsAndRecoveryCandidates() async throws {
        let arguments: [String: LuminaJSONValue] = ["query": .string("Breakfast")]
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.find", arguments: arguments)])
        let tool = AnyLuminaAgentTool(schema: readSchema) { _, _ in
            XCTFail("Unknown tool must not invoke another tool implicitly.")
            return LuminaToolResult(callID: UUID(), toolName: "record.read", status: .succeeded)
        }
        let runtime = LuminaAgentRuntime(tools: [tool], stepGenerator: model, configuration: correctionConfiguration)

        _ = await runtime.run(request: LuminaAgentRequest(text: "Find the breakfast record."))
        let observations = await model.observations
        let failure = try failureObject(in: XCTUnwrap(observations.last))

        XCTAssertEqual(failure["toolName"], .string("record.find"))
        XCTAssertEqual(failure["arguments"], .object(arguments))
        XCTAssertFalse(try XCTUnwrap(failure["reason"]?.stringValue).isEmpty)
        XCTAssertEqual(failure["code"], .string("unknown_tool"))
        XCTAssertEqual(failure["retryPolicy"], .string("discover_tool"))
        XCTAssertEqual(failure["suggestedCall"], .null)
        // The feedback must name a registered candidate instead of repeating the invalid name alone.
        let encoded = try JSONEncoder().encode(failure)
        XCTAssertTrue(try XCTUnwrap(String(data: encoded, encoding: .utf8)).contains("record.read"))
    }

    func testInvalidTypeFeedbackIdentifiesFieldAndProvidesExactToolSchema() async throws {
        let executions = CorrectionExecutionLog()
        let arguments: [String: LuminaJSONValue] = ["title": .number(42)]
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.create", arguments: arguments)])
        let runtime = LuminaAgentRuntime(tools: [successfulWriteTool(executions: executions)],
                                         stepGenerator: model, configuration: correctionConfiguration)

        _ = await runtime.run(request: LuminaAgentRequest(text: "Create a record."))
        let observations = await model.observations
        let failure = try failureObject(in: XCTUnwrap(observations.last))
        let calls = await executions.calls

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(failure["toolName"], .string("record.create"))
        XCTAssertEqual(failure["arguments"], .object(arguments))
        XCTAssertFalse(try XCTUnwrap(failure["reason"]?.stringValue).isEmpty)
        XCTAssertEqual(failure["code"], .string("validation_failed"))
        XCTAssertEqual(failure["retryPolicy"], .string("correct_arguments"))
        let fields = try JSONEncoder().encode(XCTUnwrap(failure["fieldErrors"]))
        XCTAssertTrue(try XCTUnwrap(String(data: fields, encoding: .utf8)).contains("title"))
        let schema = try JSONEncoder().encode(XCTUnwrap(failure["toolSchema"]))
        let schemaText = try XCTUnwrap(String(data: schema, encoding: .utf8))
        XCTAssertTrue(schemaText.contains("record.create"))
        XCTAssertTrue(schemaText.contains("string"))
    }

    func testMissingIdentifierProvidesRealLookupSchemaWithoutInventingRequiredQuery() async throws {
        let failure = try await missingIdentifierFeedback(arguments: ["title": .string("New title")])
        XCTAssertEqual(failure["retryPolicy"], .string("prerequisite"))
        XCTAssertEqual(failure["suggestedCall"], .null)
        let candidates = try XCTUnwrap(failure["availableTools"])
        let text = String(decoding: try JSONEncoder().encode(candidates), as: UTF8.self)
        XCTAssertTrue(text.contains("record.search"))
        XCTAssertTrue(text.contains("query"))
        XCTAssertFalse(text.contains("New title"))
    }

    func testMissingIdentifierSuggestsLookupOnlyWhenKnownArgumentsSatisfyItsSchema() async throws {
        let failure = try await missingIdentifierFeedback(arguments: ["query": .string("Breakfast"), "title": .string("New title")])
        XCTAssertEqual(failure["suggestedCall"], .object([
            "toolName": .string("record.search"), "arguments": .object(["query": .string("Breakfast")])
        ]))
        XCTAssertEqual(failure["retryPolicy"], .string("prerequisite"))
    }

    private func missingIdentifierFeedback(arguments: [String: LuminaJSONValue]) async throws -> [String: LuminaJSONValue] {
        let update = AnyLuminaAgentTool(schema: LuminaToolSchema(
            name: "record.update", description: "Update an existing record.",
            parameters: [
                LuminaToolParameterSchema(name: "recordIdentifier", type: .string, description: "An observed record ID."),
                LuminaToolParameterSchema(name: "title", type: .string, description: "New title.", required: false),
                LuminaToolParameterSchema(name: "query", type: .string, description: "Existing record query.", required: false)
            ], sideEffect: .appLocalWrite
        )) { _, _ in
            XCTFail("An update without the identifier must never execute.")
            return LuminaToolResult(callID: UUID(), toolName: "record.update", status: .failed)
        }
        let lookup = AnyLuminaAgentTool(schema: LuminaToolSchema(
            name: "record.search", description: "Find the existing record ID.",
            parameters: [LuminaToolParameterSchema(name: "query", type: .string, description: "The user's existing object query.")],
            sideEffect: .readOnly
        )) { _, _ in
            XCTFail("Correction feedback must not execute a suggested call implicitly.")
            return LuminaToolResult(callID: UUID(), toolName: "record.search", status: .succeeded)
        }
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.update", arguments: arguments)])
        let runtime = LuminaAgentRuntime(tools: [update, lookup], stepGenerator: model, configuration: correctionConfiguration)
        _ = await runtime.run(request: LuminaAgentRequest(text: "Rename the breakfast record."))
        let observations = await model.observations
        return try failureObject(in: XCTUnwrap(observations.last))
    }

    func testPermissionDenialFeedbackReachesModelWithoutExecutingTool() async throws {
        let executions = CorrectionExecutionLog()
        let arguments: [String: LuminaJSONValue] = ["title": .string("Breakfast")]
        let model = CorrectionRecordingModel(calls: [LuminaToolCall(toolName: "record.create", arguments: arguments)])
        let runtime = LuminaAgentRuntime(
            tools: [successfulWriteTool(executions: executions)], stepGenerator: model,
            configuration: correctionConfiguration, permissionGate: CorrectionDenyPermissionGate()
        )

        _ = await runtime.run(request: LuminaAgentRequest(text: "Create a record."))
        let observations = await model.observations
        let observed = try XCTUnwrap(observations.last)
        let failure = try failureObject(in: observed)
        let calls = await executions.calls

        XCTAssertEqual(calls.count, 0)
        XCTAssertEqual(failure["toolName"], .string("record.create"))
        XCTAssertEqual(failure["arguments"], .object(arguments))
        XCTAssertTrue(try XCTUnwrap(failure["reason"]?.stringValue).contains("Authorization denied by test"))
        XCTAssertEqual(failure["code"], .string("permission_denied"))
        XCTAssertEqual(failure["retryPolicy"], .string("request_permission"))
    }

    private var correctionConfiguration: LuminaAgentRuntimeConfiguration {
        luminaTestRuntimeConfiguration(maximumConsecutiveReplayObservations: 4)
    }

    private var readSchema: LuminaToolSchema {
        LuminaToolSchema(name: "record.read", description: "Read a record.", parameters: [], sideEffect: .readOnly)
    }

    private var writeSchema: LuminaToolSchema {
        LuminaToolSchema(
            name: "record.create", description: "Create a record.",
            parameters: [LuminaToolParameterSchema(name: "title", type: .string, description: "Record title.")],
            sideEffect: .appLocalWrite, idempotencyPolicy: "caller_keyed"
        )
    }

    private func successfulWriteTool(executions: CorrectionExecutionLog) -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(schema: writeSchema) { arguments, _ in
            await executions.record(arguments)
            return LuminaToolResult(callID: UUID(), toolName: "record.create", status: .succeeded,
                                    output: ["id": .string("created-once")])
        }
    }

    private func failureObject(in observation: LuminaReActObservation,
                               file: StaticString = #filePath, line: UInt = #line) throws -> [String: LuminaJSONValue] {
        let value = try XCTUnwrap(observation.output["failure"], "Model did not receive structured failure feedback.",
                                  file: file, line: line)
        guard case let .object(failure) = value else {
            XCTFail("Failure feedback must be a JSON object.", file: file, line: line)
            return [:]
        }
        return failure
    }
}

private actor CorrectionRecordingModel: LuminaReActStepGenerator {
    private var calls: [LuminaToolCall]
    private(set) var observations: [LuminaReActObservation] = []

    init(calls: [LuminaToolCall]) { self.calls = calls }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        if let observation = context.trace.observations.last { observations.append(observation) }
        guard !calls.isEmpty else { return .result("done") }
        return .action(thought: "Use observed feedback to complete the request.", call: calls.removeFirst())
    }
}

private actor CorrectionExecutionLog {
    private(set) var calls: [[String: LuminaJSONValue]] = []
    func record(_ arguments: [String: LuminaJSONValue]) { calls.append(arguments) }
}

private struct CorrectionDenyPermissionGate: LuminaPermissionGate {
    func decision(for call: LuminaToolCall, schema: LuminaToolSchema,
                  request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        .denied(reason: "Authorization denied by test; user approval is required.")
    }
}

private struct CorrectionRejectingHook: LuminaAgentRuntimeHook {
    var failure: [String: LuminaJSONValue]

    func handle(event: LuminaAgentRuntimeHookEvent,
                context: LuminaAgentRuntimeHookContext) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .beforeTool, context.toolCall?.toolName == "record.create" else { return [] }
        return [.rejectToolCallForValidation(reason: "Read the current time before writing.", failure: failure)]
    }
}
