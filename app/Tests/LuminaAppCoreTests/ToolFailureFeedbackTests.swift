import XCTest
import Foundation
import LuminaAgentRuntime
@testable import LuminaAppCore

final class ToolFailureFeedbackTests: XCTestCase {
    func testInvalidReminderDateNeverCreatesAnUndatedItem() async throws {
        let store = LuminaVolatileCalendarStore()
        let tool = LuminaReminderCreateTool(store: store)
        let arguments: [String: LuminaJSONValue] = ["title": .string("吃早餐"), "dueDateISO": .string("明天八点")]
        let result = try await tool.call(arguments: arguments, cancellation: LuminaCancellationToken())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailed, true)
        let failure = try failure(result.output)
        XCTAssertEqual(failure.string("code"), "invalid_date")
        XCTAssertEqual(failure["arguments"], .object(arguments))
        XCTAssertEqual(failure["suggestedCall"], LuminaToolFailureFeedback.currentTimeCall)
        XCTAssertEqual(failure.string("retryPolicy"), "prerequisite")
        let reminders = await store.allReminders()
        XCTAssertTrue(reminders.isEmpty)
    }

    func testSuccessfulReminderReportsActualDateAndArguments() async throws {
        let store = LuminaVolatileCalendarStore()
        let tool = LuminaReminderCreateTool(store: store)
        let date = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let arguments: [String: LuminaJSONValue] = ["title": .string("吃早餐"), "dueDateISO": .string(date)]
        let result = try await tool.call(arguments: arguments, cancellation: LuminaCancellationToken())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertNil(result.validationFailed)
        XCTAssertEqual(result.output.string("dueDateISO"), date)
        XCTAssertEqual(result.output["executedArguments"], .object(arguments))
        let reminders = await store.allReminders()
        XCTAssertEqual(reminders.count, 1)
    }

    func testPastDatesTypesRequiredFieldsAndDateRangesFailBeforeWriting() throws {
        let tool = LuminaCalendarCreateTool(store: LuminaVolatileCalendarStore())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [([String: LuminaJSONValue], String)] = [
            (["title": .string("开会")], "invalid_parameters"),
            (["title": .number(3), "startDateISO": .string("2099-01-01T08:00:00+08:00")], "invalid_parameters"),
            (["title": .string("开会"), "startDateISO": .string("2000-01-01T08:00:00+08:00")], "past_date"),
            (["title": .string("开会"), "startDateISO": .string("2099-01-01T08:00:00+08:00"), "endDateISO": .string("not-a-date")], "invalid_date"),
            (["title": .string("开会"), "startDateISO": .string("2099-01-01T08:00:00+08:00"), "endDateISO": .string("2099-01-01T07:00:00+08:00")], "invalid_date_range")
        ]
        for (arguments, code) in cases {
            let result = try XCTUnwrap(LuminaToolFailureFeedback.validateScheduledWrite(schema: tool.schema, arguments: arguments, now: now))
            XCTAssertEqual(result.validationFailed, true)
            XCTAssertEqual(try failure(result.output).string("code"), code)
            XCTAssertNotNil(try failure(result.output)["toolSchema"])
        }
    }

    func testNotificationRejectsAbsentAmbiguousAndNonpositiveTimes() async throws {
        let store = LuminaScheduledNotificationStore()
        let tool = LuminaNotificationScheduleTool(store: store)
        let cases: [[String: LuminaJSONValue]] = [
            ["title": .string("出门")],
            ["title": .string("出门"), "timeIntervalSeconds": .number(-1)],
            ["title": .string("出门"), "timeIntervalSeconds": .number(0)],
            ["title": .string("出门"), "dateISO": .string("2099-01-01T08:00:00+08:00"), "timeIntervalSeconds": .number(60)]
        ]
        for arguments in cases {
            let result = try await tool.call(arguments: arguments, cancellation: LuminaCancellationToken())
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.validationFailed, true)
        }
        let notifications = await store.all()
        XCTAssertTrue(notifications.isEmpty)
    }

    func testExplicitNotificationTimeProducesASingleTriggerCorrectionAfterConflict() throws {
        let schema = LuminaNotificationScheduleTool().schema
        let arguments: [String: LuminaJSONValue] = [
            "title": .string("吃早餐"), "dateISO": .string("2026-09-09T08:00:00+08:00"), "timeIntervalSeconds": .number(0)
        ]
        let clock = LuminaReActObservation(toolName: "device.current_time", status: .succeeded, summary: "Clock", output: [
            "iso8601": .string("2026-09-08T16:00:00+08:00"), "timeZoneIdentifier": .string("Asia/Shanghai")
        ])
        let trace = LuminaReActTrace(steps: [.observation(clock)])
        let result = try XCTUnwrap(LuminaToolFailureFeedback.validateScheduledWrite(
            schema: schema, arguments: arguments, now: ISO8601DateFormatter().date(from: "2026-09-08T16:00:00+08:00")!
        ))
        let observation = LuminaReActObservation(toolName: schema.name, status: result.status, summary: result.errorMessage ?? "", output: result.output)
        let enriched = LuminaToolFailureFeedback.enrichedObservation(
            observation, arguments: arguments, availableTools: [schema],
            request: "明天早上八点发通知叫我吃早餐", trace: trace
        )
        let details = try failure(enriched.output)
        XCTAssertEqual(details["suggestedCall"], .object([
            "toolName": .string(schema.name), "arguments": .object([
                "title": .string("吃早餐"), "dateISO": .string("2026-09-09T08:00:00+08:00")
            ])
        ]))
        XCTAssertEqual(details.string("reason"), try failure(result.output).string("reason"))
        let unresolved = LuminaToolFailureFeedback.enrichedObservation(
            observation, arguments: arguments, availableTools: [schema], request: "发通知叫我吃早餐", trace: trace
        )
        XCTAssertEqual(try failure(unresolved.output)["suggestedCall"], .null, "An ambiguous request must not choose between conflicting trigger modes")
    }

    func testFractionalISOAndOffsetsPreserveSameInstant() throws {
        let local = try XCTUnwrap(LuminaToolFailureFeedback.parseDate("2099-01-01T00:30:00.125+08:00"))
        let utc = try XCTUnwrap(LuminaToolFailureFeedback.parseDate("2098-12-31T16:30:00.125Z"))
        XCTAssertEqual(local, utc)
    }

    func testLegacyFailuresExplainPermissionCancellationAndUnknownWriteOutcome() throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let cases: [(LuminaToolResultStatus, String, String, String)] = [
            (.denied, "提醒事项权限已被拒绝。", "permission_denied", "request_permission"),
            (.cancelled, "User cancelled", "cancelled", "stop"),
            (.failed, "Connection lost after save", "execution_uncertain", "verify_before_retry"),
            (.failed, "missing required parameter title", "invalid_parameters", "verify_before_retry")
        ]
        for (status, reason, code, policy) in cases {
            let observation = LuminaToolFailureFeedback.enrichedObservation(
                LuminaReActObservation(toolName: schema.name, status: status, summary: reason, errorMessage: reason),
                arguments: [:], availableTools: [schema]
            )
            let details = try failure(observation.output)
            XCTAssertEqual(details.string("code"), code)
            XCTAssertEqual(details.string("retryPolicy"), policy)
            XCTAssertEqual(observation.errorMessage, reason)
            XCTAssertEqual(details["suggestedCall"], .null)
        }
    }

    func testUnknownToolSuggestsOnlyRegisteredRelatedSchemas() throws {
        let store = LuminaVolatileCalendarStore()
        let schemas = [LuminaReminderCreateTool(store: store).schema, LuminaCalendarCreateTool(store: store).schema, LuminaCurrentTimeTool().schema]
        let observation = LuminaToolFailureFeedback.enrichedObservation(
            LuminaReActObservation(toolName: "reminder.add", status: .failed, summary: "Tool is not registered."),
            arguments: ["title": .string("吃早餐")], availableTools: schemas
        )
        let details = try failure(observation.output)
        XCTAssertEqual(details.string("code"), "unknown_tool")
        XCTAssertEqual(details["availableTools"], .array([LuminaToolFailureFeedback.schemaValue(schemas[0])]))
        XCTAssertEqual(details["suggestedCall"], .null)
    }

    func testMissingIdentifierRequiresSearchWithoutInventingAnID() throws {
        let schema = LuminaToolSchema(name: "calendar.update", description: "修改事件", parameters: [LuminaToolParameterSchema(name: "id", type: .string, description: "事件 identifier")], sideEffect: .systemWrite)
        let observation = LuminaToolFailureFeedback.enrichedObservation(
            LuminaReActObservation(toolName: schema.name, status: .failed, summary: "缺少事件 identifier。"),
            availableTools: [schema]
        )
        let details = try failure(observation.output)
        XCTAssertEqual(details.string("code"), "missing_identifier")
        XCTAssertTrue(details.string("guidance")?.contains("Search") == true)
        XCTAssertEqual(details["suggestedCall"], .null)
    }

    func testStructuredHostFailureAndNestedOutputAreNotOverwritten() throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let result = LuminaToolFailureFeedback.validationFailure(schema: schema, arguments: [:], reason: "Missing title", field: "title", guidance: "Ask for title")
        var output = result.output
        output["nested"] = .object(["ids": .array([.string("actual-id")]), "retry": .bool(false)])
        let observation = LuminaReActObservation(toolName: schema.name, status: .failed, summary: "fallback", output: output)
        XCTAssertEqual(LuminaToolFailureFeedback.enrichedObservation(observation, availableTools: [schema]).output, output)
    }

    func testRelativeTimeGuardRequiresRealTimeObservationInCurrentRequest() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let call = LuminaToolCall(toolName: schema.name, arguments: ["title": .string("吃早餐"), "dueDateISO": .string("2099-01-01T08:00:00+08:00")])
        let policy = LuminaToolRecoveryRuntimePolicy()
        var context = LuminaAgentRuntimeHookContext(request: LuminaAgentRequest(text: "明天早上八点提醒我吃早餐"), availableTools: [schema, LuminaCurrentTimeTool().schema], toolCall: call)
        let rejected = try await policy.handle(event: .beforeTool, context: context)
        guard case let .rejectToolCallForValidation(_, details) = rejected.first else { return XCTFail("Must reject as a correctable pre-write validation failure") }
        XCTAssertEqual(details.string("code"), "missing_current_time")
        XCTAssertEqual(details["suggestedCall"], LuminaToolFailureFeedback.currentTimeCall)
        let actualTime = try await LuminaCurrentTimeTool().call(arguments: [:], cancellation: LuminaCancellationToken())
        context.trace.steps = [.observation(LuminaReActObservation(toolName: actualTime.toolName, status: actualTime.status, summary: "time", output: actualTime.output))]
        let hints = LuminaToolFailureFeedback.scheduleHints(request: context.request.text, trace: context.trace)
        if case let .object(hint) = hints.first {
            context.toolCall?.arguments["dueDateISO"] = hint["dateISO"]
        }
        let accepted = try await policy.handle(event: .beforeTool, context: context)
        XCTAssertTrue(accepted.isEmpty)
        context.trace.steps = []
        let nextRequest = try await policy.handle(event: .beforeTool, context: context)
        XCTAssertFalse(nextRequest.isEmpty)
    }

    func testOneParameterCorrectionIsAllowedThenStopsWithSpecificReason() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let failureResult = LuminaToolFailureFeedback.validationFailure(schema: schema, arguments: ["dueDateISO": .string("bad")], code: "invalid_date", reason: "Invalid dueDateISO", field: "dueDateISO", guidance: "Use ISO8601")
        let observation = LuminaReActObservation(toolName: schema.name, status: .failed, summary: "Invalid dueDateISO", output: failureResult.output)
        var context = LuminaAgentRuntimeHookContext(request: LuminaAgentRequest(text: "提醒我"), availableTools: [schema], trace: LuminaReActTrace(steps: [.observation(observation)]))
        let policy = LuminaToolRecoveryRuntimePolicy()
        let first = try await policy.handle(event: .stepContextReady, context: context)
        XCTAssertTrue(first.isEmpty)
        context.trace.steps.append(.observation(observation))
        let second = try await policy.handle(event: .stepContextReady, context: context)
        guard case let .fail(markdown, _) = second.first else { return XCTFail("A second same-category validation error must stop") }
        XCTAssertTrue(markdown.contains("Invalid dueDateISO"))
    }

    func testPermissionDeniedAndUncertainWritesCannotBeRetried() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        for (status, reason) in [(LuminaToolResultStatus.denied, "Permission denied"), (.cancelled, "Cancelled"), (.failed, "Write connection lost")] {
            let context = LuminaAgentRuntimeHookContext(request: LuminaAgentRequest(text: "提醒我"), availableTools: [schema], trace: LuminaReActTrace(steps: [.observation(LuminaReActObservation(toolName: schema.name, status: status, summary: reason))]), toolCall: LuminaToolCall(toolName: schema.name, arguments: ["title": .string("早餐")]))
            let directives = try await LuminaToolRecoveryRuntimePolicy().handle(event: .beforeTool, context: context)
            guard case .fail = directives.first else { return XCTFail("Unsafe retry must be stopped") }
        }
    }

    func testSameToolSuccessResetsCorrectionBudgetButOtherToolSuccessDoesNot() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let failureResult = LuminaToolFailureFeedback.validationFailure(schema: schema, arguments: [:], reason: "Missing title", field: "title", guidance: "Supply requested title")
        let failed = LuminaReActObservation(toolName: schema.name, status: .failed, summary: "Missing title", output: failureResult.output)
        let policy = LuminaToolRecoveryRuntimePolicy()
        for (successfulTool, shouldStop) in [(schema.name, false), ("device.current_time", true)] {
            let context = LuminaAgentRuntimeHookContext(
                request: LuminaAgentRequest(text: "提醒我两件事"), availableTools: [schema],
                trace: LuminaReActTrace(steps: [
                    .observation(failed),
                    .observation(LuminaReActObservation(toolName: successfulTool, status: .succeeded, summary: "Completed")),
                    .observation(failed)
                ])
            )
            let directives = try await policy.handle(event: .stepContextReady, context: context)
            XCTAssertEqual(!directives.isEmpty, shouldStop)
        }
    }

    func testNewInvalidFieldHasItsOwnCorrectionBudget() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        func observation(field: String) -> LuminaReActObservation {
            let result = LuminaToolFailureFeedback.validationFailure(
                schema: schema, arguments: [:], code: "validation_failed",
                reason: "Invalid \(field)", field: field, guidance: "Correct this field from the user request"
            )
            return LuminaReActObservation(toolName: schema.name, status: .failed, summary: "Invalid \(field)", output: result.output)
        }
        let titleFailure = observation(field: "title")
        let dateFailure = observation(field: "dueDateISO")
        var context = LuminaAgentRuntimeHookContext(
            request: LuminaAgentRequest(text: "提醒我"), availableTools: [schema],
            trace: LuminaReActTrace(steps: [.observation(titleFailure), .observation(dateFailure)])
        )
        let policy = LuminaToolRecoveryRuntimePolicy()
        let firstDateFailure = try await policy.handle(event: .stepContextReady, context: context)
        XCTAssertTrue(firstDateFailure.isEmpty, "Correcting title must not consume the new dueDateISO correction")
        context.trace.steps.append(.observation(dateFailure))
        let secondDateFailure = try await policy.handle(event: .stepContextReady, context: context)
        guard case .fail = secondDateFailure.first else { return XCTFail("The same date field still only gets one correction") }
    }

    func testFieldErrorOrderingCannotResetCorrectionBudget() async throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let steps = [["title", "notes"], ["notes", "title", "notes"]].map { fields in
            let feedback = LuminaToolFailureFeedback.payload(
                code: "validation_failed", reason: "Invalid fields", toolName: schema.name,
                arguments: [:], schema: schema,
                fieldErrors: fields.map { .object(["field": .string($0), "reason": .string("Invalid type")]) },
                retryPolicy: "correct_arguments", guidance: "Follow the declared JSON types"
            )
            return LuminaReActStep.observation(LuminaReActObservation(toolName: schema.name, status: .failed, summary: "Invalid fields", output: ["failure": feedback]))
        }
        let context = LuminaAgentRuntimeHookContext(request: LuminaAgentRequest(text: "提醒我"), availableTools: [schema], trace: LuminaReActTrace(steps: steps))
        let directives = try await LuminaToolRecoveryRuntimePolicy().handle(event: .stepContextReady, context: context)
        guard case .fail = directives.first else { return XCTFail("The same field set must have a stable correction category") }
    }

    func testCorrectingStartTimeDoesNotConsumeTheEndTimeCorrectionBudget() async throws {
        let schema = LuminaCalendarCreateTool(store: LuminaVolatileCalendarStore()).schema
        func observation(code: String, field: String) -> LuminaReActObservation {
            let result = LuminaToolFailureFeedback.validationFailure(
                schema: schema, arguments: [:], code: code, reason: "Invalid \(field)", field: field, guidance: "Correct the reported date field"
            )
            return LuminaReActObservation(toolName: schema.name, status: .failed, summary: "Invalid \(field)", output: result.output)
        }
        let startFailure = observation(code: "requested_time_mismatch", field: "startDateISO")
        let endFailure = observation(code: "invalid_date_range", field: "endDateISO")
        var context = LuminaAgentRuntimeHookContext(
            request: LuminaAgentRequest(text: "修改日程时间"), availableTools: [schema],
            trace: LuminaReActTrace(steps: [.observation(startFailure), .observation(endFailure)])
        )
        let policy = LuminaToolRecoveryRuntimePolicy()
        let firstEndFailure = try await policy.handle(event: .stepContextReady, context: context)
        XCTAssertTrue(firstEndFailure.isEmpty, "A newly exposed endDateISO error needs its own correction")
        context.trace.steps.append(.observation(observation(code: "past_date", field: "endDateISO")))
        let repeatedEndFailure = try await policy.handle(event: .stepContextReady, context: context)
        guard case .fail = repeatedEndFailure.first else { return XCTFail("Date errors on the same field still share one correction budget") }
    }

    private func failure(_ output: [String: LuminaJSONValue]) throws -> [String: LuminaJSONValue] {
        let value = try XCTUnwrap(output["failure"])
        guard case let .object(details) = value else { throw NSError(domain: "Invalid failure payload", code: 1) }
        return details
    }
}
