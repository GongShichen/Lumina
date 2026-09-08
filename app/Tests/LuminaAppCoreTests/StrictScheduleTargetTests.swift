import Foundation
import XCTest
import LuminaAgentRuntime
@testable import LuminaAppCore

final class StrictScheduleTargetTests: XCTestCase {
    func testChineseDayAnchorsAndClockFormsResolveInTheSuppliedTimeZone() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        let cases: [(String, String)] = [
            ("今天下午3点提醒我喝水", "2026-09-08T15:00:00+08:00"),
            ("明天早上八点提醒我吃早餐", "2026-09-09T08:00:00+08:00"),
            ("后天上午九点半提醒我出门", "2026-09-10T09:30:00+08:00"),
            ("明早六点四十五分提醒我跑步", "2026-09-09T06:45:00+08:00"),
            ("今晚八点提醒我看书", "2026-09-08T20:00:00+08:00"),
            ("今晚八点零五分提醒我看书", "2026-09-08T20:05:00+08:00"),
            ("明天08:30提醒我吃早餐", "2026-09-09T08:30:00+08:00"),
            ("今天14:05提醒我喝水", "2026-09-08T14:05:00+08:00"),
            ("明天八点提醒我吃早餐", "2026-09-09T08:00:00+08:00")
        ]
        for (request, expected) in cases {
            let target = try singleTarget(request, now: now, calendar: calendar)
            XCTAssertEqual(target.date, try date(expected), request)
            XCTAssertEqual(target.toolDomain, "reminder", request)
            XCTAssertEqual(target.clause, request, request)
        }
    }

    func testEnglishDayAnchorsAndMeridiemResolveExactly() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        let cases: [(String, String)] = [
            ("Remind me today at 8 am to eat breakfast", "2026-09-08T08:00:00+08:00"),
            ("Remind me tomorrow at 8 pm to read", "2026-09-09T20:00:00+08:00"),
            ("Remind me tonight at 8 pm to read", "2026-09-08T20:00:00+08:00"),
            ("Remind me tomorrow at 08:30 to eat breakfast", "2026-09-09T08:30:00+08:00"),
            ("Remind me tomorrow at 8 to eat breakfast", "2026-09-09T08:00:00+08:00"),
            ("Remind me tomorrow at 12 am to check in", "2026-09-09T00:00:00+08:00"),
            ("Remind me tomorrow at 12 pm to eat lunch", "2026-09-09T12:00:00+08:00")
        ]
        for (request, expected) in cases {
            let target = try singleTarget(request, now: now, calendar: calendar)
            XCTAssertEqual(target.date, try date(expected), request)
        }
    }

    func testRelativeDurationsUseTheObservedInstantWithoutDroppingSeconds() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T23:50:20+08:00")
        let cases: [(String, TimeInterval)] = [
            ("十五分钟后提醒我喝水", 15 * 60),
            ("30分钟后提醒我喝水", 30 * 60),
            ("两小时后提醒我出门", 2 * 60 * 60),
            ("3小时后提醒我出门", 3 * 60 * 60),
            ("Remind me in 45 minutes to drink water", 45 * 60),
            ("Remind me in twenty five minutes to drink water", 25 * 60),
            ("Remind me in fifty-nine minutes to drink water", 59 * 60),
            ("Remind me in two hours to leave", 2 * 60 * 60)
        ]
        for (request, duration) in cases {
            let target = try singleTarget(request, now: now, calendar: calendar)
            XCTAssertEqual(target.date, now.addingTimeInterval(duration), request)
        }
    }

    func testMissingDayOrClockDoesNotInventAScheduledTime() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        for request in [
            "提醒我吃早餐", "明天提醒我吃早餐", "明天早上提醒我吃早餐",
            "八点提醒我吃早餐", "下午三点创建日程开会",
            "Remind me to eat breakfast", "Remind me tomorrow to eat breakfast",
            "Remind me at 8 am to eat breakfast"
        ] {
            XCTAssertTrue(LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar).isEmpty, request)
        }
    }

    func testInvalidClockComponentsAreRejectedInsteadOfClampedOrCarried() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        for request in [
            "今天下午25点提醒我喝水", "明天八点六十分提醒我吃早餐",
            "明天25:00提醒我吃早餐", "明天08:60提醒我吃早餐",
            "Remind me tomorrow at 25:00 to eat breakfast",
            "Remind me tomorrow at 08:60 to eat breakfast",
            "Remind me tomorrow at 13 pm to eat breakfast"
        ] {
            XCTAssertTrue(LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar).isEmpty, request)
        }
    }

    func testAlternativeTimesDoNotProduceAnArbitraryTarget() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        for request in [
            "明天早上八点或九点提醒我吃早餐",
            "Remind me tomorrow at 8 am or 9 am to eat breakfast"
        ] {
            XCTAssertTrue(LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar).isEmpty, request)
        }
    }

    func testCompoundRequestKeepsSeparateDatesAndToolDomains() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        let request = "明天早上八点提醒我吃早餐，并在明天下午三点创建日程开会"
        let targets = LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar)
        XCTAssertEqual(targets.count, 2)
        let reminder = try XCTUnwrap(targets.first { $0.toolDomain == "reminder" })
        let event = try XCTUnwrap(targets.first { $0.toolDomain == "calendar" })
        XCTAssertEqual(reminder.date, try date("2026-09-09T08:00:00+08:00"))
        XCTAssertEqual(event.date, try date("2026-09-09T15:00:00+08:00"))
        XCTAssertTrue(reminder.clause.contains("提醒我吃早餐"))
        XCTAssertFalse(reminder.clause.contains("创建日程"))
        XCTAssertTrue(event.clause.contains("创建日程开会"))
        XCTAssertFalse(event.clause.contains("提醒我吃早餐"))
    }

    func testUpdateUsesDestinationTimeAndKeepsTheOriginalClause() throws {
        let calendar = try calendar("Asia/Shanghai")
        let now = try date("2026-09-08T06:15:20+08:00")
        let request = "把明天早上七点的日程改到七点半"
        let target = try singleTarget(request, now: now, calendar: calendar)
        XCTAssertEqual(target.date, try date("2026-09-09T07:30:00+08:00"))
        XCTAssertEqual(target.toolDomain, "calendar")
        XCTAssertEqual(target.clause, request)
    }

    func testObservedCalendarTimeZoneDeterminesTomorrowAcrossDateBoundaries() throws {
        let now = try date("2026-09-08T00:30:00Z")
        let request = "明天早上八点提醒我吃早餐"
        let shanghai = try singleTarget(request, now: now, calendar: calendar("Asia/Shanghai"))
        let newYork = try singleTarget(request, now: now, calendar: calendar("America/New_York"))
        XCTAssertEqual(shanghai.date, try date("2026-09-09T08:00:00+08:00"))
        XCTAssertEqual(newYork.date, try date("2026-09-08T08:00:00-04:00"))
    }

    func testSpringDSTGapDoesNotSilentlyShiftToAnExistingTime() throws {
        let calendar = try calendar("America/New_York")
        let now = try date("2026-03-07T12:00:00-05:00")
        for request in ["明天02:30提醒我出门", "Remind me tomorrow at 02:30 to leave"] {
            XCTAssertTrue(LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar).isEmpty, request)
        }
        let valid = try singleTarget("明天03:30提醒我出门", now: now, calendar: calendar)
        XCTAssertEqual(valid.date, try date("2026-03-08T03:30:00-04:00"))
    }

    func testAutumnDSTFoldDoesNotPickOneOfTwoPossibleInstants() throws {
        let calendar = try calendar("America/New_York")
        let now = try date("2026-10-31T12:00:00-04:00")
        for request in ["明天01:30提醒我出门", "Remind me tomorrow at 01:30 to leave"] {
            XCTAssertTrue(LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar).isEmpty, request)
        }
        let valid = try singleTarget("明天02:30提醒我出门", now: now, calendar: calendar)
        XCTAssertEqual(valid.date, try date("2026-11-01T02:30:00-05:00"))
    }

    func testScheduleHintsRequireSuccessfulRealCurrentTimeWithValidISOAndTimeZone() {
        let request = "明天早上八点提醒我吃早餐"
        let validOutput: [String: LuminaJSONValue] = [
            "iso8601": .string("2026-09-08T06:15:20+08:00"),
            "timeZoneIdentifier": .string("Asia/Shanghai")
        ]
        let invalidObservations = [
            timeObservation(status: .failed, output: validOutput),
            timeObservation(status: .denied, output: validOutput),
            timeObservation(toolName: "calendar.search", output: validOutput),
            timeObservation(output: ["iso8601": validOutput["iso8601"]!]),
            timeObservation(output: ["timeZoneIdentifier": validOutput["timeZoneIdentifier"]!]),
            timeObservation(output: ["iso8601": .string("明天"), "timeZoneIdentifier": .string("Asia/Shanghai")]),
            timeObservation(output: ["iso8601": validOutput["iso8601"]!, "timeZoneIdentifier": .string("Unknown/TimeZone")])
        ]
        XCTAssertTrue(LuminaToolFailureFeedback.scheduleHints(request: request, trace: LuminaReActTrace()).isEmpty)
        for observation in invalidObservations {
            let trace = LuminaReActTrace(steps: [.observation(observation)])
            XCTAssertTrue(LuminaToolFailureFeedback.scheduleHints(request: request, trace: trace).isEmpty, "Invalid source: \(observation)")
        }
        let trace = LuminaReActTrace(steps: [.observation(timeObservation(output: validOutput))])
        XCTAssertEqual(LuminaToolFailureFeedback.scheduleHints(request: request, trace: trace).count, 1)
        XCTAssertTrue(LuminaToolFailureFeedback.scheduleHints(request: "明天提醒我吃早餐", trace: trace).isEmpty)
    }

    func testRequestedTimeMismatchSuggestsExactReminderCallAndPreservesKnownArguments() throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let request = "明天早上八点提醒我吃早餐"
        let trace = observedClockTrace()
        for suppliedDate in ["2026-09-08T08:00:00+08:00", "2099-01-01T08:00:00+08:00"] {
            let arguments: [String: LuminaJSONValue] = [
                "title": .string("吃早餐"), "notes": .string("用户原有备注"), "dueDateISO": .string(suppliedDate)
            ]
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.scheduledTargetMismatch(
                request: request, trace: trace,
                call: LuminaToolCall(toolName: schema.name, arguments: arguments), schema: schema
            ))
            XCTAssertEqual(failure.string("code"), "requested_time_mismatch")
            XCTAssertEqual(failure["arguments"], .object(arguments))
            XCTAssertEqual(failure.string("retryPolicy"), "correct_arguments")
            XCTAssertEqual(failure["suggestedCall"], .object([
                "toolName": .string("reminder.create"),
                "arguments": .object([
                    "title": .string("吃早餐"), "notes": .string("用户原有备注"),
                    "dueDateISO": .string("2026-09-09T08:00:00+08:00")
                ])
            ]))
        }
        let matchingCall = LuminaToolCall(toolName: schema.name, arguments: [
            "title": .string("吃早餐"), "dueDateISO": .string("2026-09-09T08:00:00+08:00")
        ])
        XCTAssertNil(LuminaToolFailureFeedback.scheduledTargetMismatch(request: request, trace: trace, call: matchingCall, schema: schema))
    }

    func testPastDateEnrichmentKeepsOriginalReasonAndUsesKnownTimeWithoutInventingRequiredFields() throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let request = "明天早上八点提醒我吃早餐"
        let reason = "dueDateISO is in the past. No reminder was created."
        for includeTitle in [true, false] {
            var arguments: [String: LuminaJSONValue] = ["dueDateISO": .string("2026-09-07T08:00:00+08:00")]
            if includeTitle { arguments["title"] = .string("吃早餐") }
            let result = LuminaToolFailureFeedback.validationFailure(
                schema: schema, arguments: arguments, code: "past_date", reason: reason,
                field: "dueDateISO", guidance: "Read the current time before retrying.", needsCurrentTime: true
            )
            XCTAssertEqual(try object(result.output["failure"])["suggestedCall"], LuminaToolFailureFeedback.currentTimeCall)
            let observation = LuminaReActObservation(
                toolName: schema.name, status: .failed, summary: reason, output: result.output, errorMessage: reason
            )
            let enriched = LuminaToolFailureFeedback.enrichedObservation(
                observation, arguments: arguments, availableTools: [schema], request: request, trace: observedClockTrace()
            )
            let failure = try object(enriched.output["failure"])
            XCTAssertEqual(failure.string("code"), "past_date")
            XCTAssertEqual(failure.string("reason"), reason)
            XCTAssertEqual(enriched.errorMessage, reason)
            XCTAssertEqual(failure["arguments"], .object(arguments))
            let guidance = try object(failure["hostGuidance"])
            XCTAssertEqual(guidance.string("dateISO"), "2026-09-09T08:00:00+08:00")
            XCTAssertEqual(guidance.string("observedISO8601"), "2026-09-08T06:15:20+08:00")
            XCTAssertEqual(guidance.string("timeZoneIdentifier"), "Asia/Shanghai")
            if includeTitle {
                XCTAssertEqual(failure["suggestedCall"], .object([
                    "toolName": .string("reminder.create"),
                    "arguments": .object(["title": .string("吃早餐"), "dueDateISO": .string("2026-09-09T08:00:00+08:00")])
                ]))
            } else {
                XCTAssertEqual(failure["suggestedCall"], .null, "Missing required title must not be invented by date correction")
            }
        }
    }

    func testCompoundCorrectionMatchesEachToolDomainWithoutRoutingTheOperation() throws {
        let store = LuminaVolatileCalendarStore()
        let reminderSchema = LuminaReminderCreateTool(store: store).schema
        let calendarSchema = LuminaCalendarCreateTool(store: store).schema
        let request = "明天早上八点提醒我吃早餐，并在明天下午三点创建日程开会"
        let trace = observedClockTrace()
        let cases: [(LuminaToolSchema, String, String, String)] = [
            (reminderSchema, "吃早餐", "dueDateISO", "2026-09-09T08:00:00+08:00"),
            (calendarSchema, "开会", "startDateISO", "2026-09-09T15:00:00+08:00")
        ]
        for (schema, title, field, expectedDate) in cases {
            let call = LuminaToolCall(toolName: schema.name, arguments: ["title": .string(title), field: .string("2099-01-01T08:00:00+08:00")])
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.scheduledTargetMismatch(request: request, trace: trace, call: call, schema: schema))
            XCTAssertEqual(failure["suggestedCall"], .object([
                "toolName": .string(schema.name), "arguments": .object(["title": .string(title), field: .string(expectedDate)])
            ]))
            let matchingCall = LuminaToolCall(toolName: schema.name, arguments: ["title": .string(title), field: .string(expectedDate)])
            XCTAssertNil(LuminaToolFailureFeedback.scheduledTargetMismatch(request: request, trace: trace, call: matchingCall, schema: schema))
        }
        let calendarCall = LuminaToolCall(toolName: calendarSchema.name, arguments: [
            "title": .string("吃早餐"), "startDateISO": .string("2099-01-01T08:00:00+08:00")
        ])
        XCTAssertNil(LuminaToolFailureFeedback.scheduledTargetMismatch(
            request: "明天早上八点提醒我吃早餐", trace: trace, call: calendarCall, schema: calendarSchema
        ), "A reminder target cannot be used to rewrite a calendar operation")
    }

    func testSameDomainAmbiguousTitlesDoNotSelectOrRewriteAScheduleTarget() throws {
        let schema = LuminaReminderCreateTool(store: LuminaVolatileCalendarStore()).schema
        let request = "明天早上八点提醒我吃早餐，并在明天下午三点提醒我喝水"
        let trace = observedClockTrace()
        XCTAssertEqual(LuminaToolFailureFeedback.scheduleHints(request: request, trace: trace).count, 2)
        for title in ["待办", "明天", ""] {
            let call = LuminaToolCall(toolName: schema.name, arguments: [
                "title": .string(title), "dueDateISO": .string("2099-01-01T08:00:00+08:00")
            ])
            XCTAssertNil(LuminaToolFailureFeedback.scheduledTargetMismatch(request: request, trace: trace, call: call, schema: schema), title)
        }
        let uniqueCall = LuminaToolCall(toolName: schema.name, arguments: [
            "title": .string("喝水"), "dueDateISO": .string("2099-01-01T08:00:00+08:00")
        ])
        let uniqueFailure = try XCTUnwrap(LuminaToolFailureFeedback.scheduledTargetMismatch(request: request, trace: trace, call: uniqueCall, schema: schema))
        XCTAssertEqual(uniqueFailure["suggestedCall"], .object([
            "toolName": .string("reminder.create"),
            "arguments": .object(["title": .string("喝水"), "dueDateISO": .string("2026-09-09T15:00:00+08:00")])
        ]))
    }

    func testCalendarUpdateCorrectionPreservesObservedDurationAfterTheFailedWrite() throws {
        let schema = calendarUpdateSchema()
        let search = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore()).schema
        let request = "把明天早上七点的日程改到七点半，保持时长"
        for code in ["invalid_date_range", "requested_time_mismatch"] {
            let arguments: [String: LuminaJSONValue] = [
                "id": .string("event-actual-42"),
                "startDateISO": .string(code == "invalid_date_range" ? "2026-09-09T07:30:00+08:00" : "2026-09-09T07:00:00+08:00"),
                "endDateISO": .string("2026-09-09T07:10:00+08:00")
            ]
            let reason = "Original \(code): no calendar update was performed."
            let failure = calendarUpdateFailure(schema: schema, arguments: arguments, code: code, reason: reason)
            var trace = observedClockTrace()
            trace.steps.append(.observation(calendarLookupWithOriginalDuration()))
            trace.steps.append(.action(thought: "Move the selected event", call: LuminaToolCall(toolName: schema.name, arguments: arguments)))
            trace.steps.append(.observation(failure))
            let enriched = LuminaToolFailureFeedback.enrichedObservation(
                failure, arguments: arguments, availableTools: [schema, search], request: request, trace: trace
            )
            let feedback = try object(enriched.output["failure"])
            XCTAssertEqual(feedback.string("code"), code)
            XCTAssertEqual(feedback.string("reason"), reason)
            XCTAssertEqual(enriched.errorMessage, reason)
            XCTAssertEqual(feedback["arguments"], .object(arguments))
            XCTAssertEqual(feedback["suggestedCall"], .object([
                "toolName": .string("calendar.update"),
                "arguments": .object([
                    "id": .string("event-actual-42"),
                    "startDateISO": .string("2026-09-09T07:30:00+08:00"),
                    "endDateISO": .string("2026-09-09T08:15:00+08:00")
                ])
            ]), "The new end must preserve the observed 45-minute duration, not the failed call's duration")
        }
    }

    func testCalendarUpdateCorrectionDoesNotInventDurationWithoutMatchingLookupAndUserIntent() throws {
        let schema = calendarUpdateSchema()
        let search = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore()).schema
        let request = "把明天早上七点的日程改到七点半，保持时长"
        let cases: [(String, String, LuminaReActObservation?, String)] = [
            ("missing lookup", request, nil, "event-actual-42"),
            ("missing observed end", request, calendarLookupWithOriginalDuration(includeEnd: false), "event-actual-42"),
            ("different pending ID", request, calendarLookupWithOriginalDuration(), "event-other-99"),
            ("duration preservation not requested", "把明天早上七点的日程改到七点半", calendarLookupWithOriginalDuration(), "event-actual-42")
        ]
        for code in ["invalid_date_range", "requested_time_mismatch"] {
            for (label, userRequest, lookup, pendingID) in cases {
                let arguments: [String: LuminaJSONValue] = [
                    "id": .string(pendingID), "startDateISO": .string("2026-09-09T07:00:00+08:00"),
                    "endDateISO": .string("2026-09-09T07:10:00+08:00")
                ]
                let reason = "Original \(code): no calendar update was performed."
                let failure = calendarUpdateFailure(schema: schema, arguments: arguments, code: code, reason: reason)
                var trace = observedClockTrace()
                if let lookup { trace.steps.append(.observation(lookup)) }
                trace.steps.append(.action(thought: "Move the selected event", call: LuminaToolCall(toolName: schema.name, arguments: arguments)))
                trace.steps.append(.observation(failure))
                let enriched = LuminaToolFailureFeedback.enrichedObservation(
                    failure, arguments: arguments, availableTools: [schema, search], request: userRequest, trace: trace
                )
                let feedback = try object(enriched.output["failure"])
                XCTAssertEqual(feedback.string("code"), code, label)
                XCTAssertEqual(feedback.string("reason"), reason, label)
                XCTAssertEqual(enriched.errorMessage, reason, label)
                XCTAssertEqual(feedback["suggestedCall"], .null, "\(label): a bad end before the new start cannot be repaired using guessed duration")
            }
        }
    }

    private func calendarUpdateSchema() -> LuminaToolSchema {
        LuminaToolSchema(name: "calendar.update", description: "Update an observed event.", parameters: [
            .init(name: "id", type: .string, description: "Actual event identifier."),
            .init(name: "startDateISO", type: .dateISO8601, description: "New start.", required: false),
            .init(name: "endDateISO", type: .dateISO8601, description: "New end.", required: false)
        ], sideEffect: .systemWrite)
    }

    private func calendarLookupWithOriginalDuration(includeEnd: Bool = true) -> LuminaReActObservation {
        var item: [String: LuminaJSONValue] = [
            "id": .string("event-actual-42"), "title": .string("项目同步"), "timeZone": .string("Asia/Shanghai"),
            "startDateISO": .string("2026-09-09T07:00:00+08:00")
        ]
        if includeEnd { item["endDateISO"] = .string("2026-09-09T07:45:00+08:00") }
        return LuminaReActObservation(toolName: "calendar.search", status: .succeeded, summary: "One matching event", output: ["items": .array([.object(item)])])
    }

    private func calendarUpdateFailure(
        schema: LuminaToolSchema,
        arguments: [String: LuminaJSONValue],
        code: String,
        reason: String
    ) -> LuminaReActObservation {
        let result = LuminaToolFailureFeedback.validationFailure(
            schema: schema, arguments: arguments, code: code, reason: reason,
            field: code == "invalid_date_range" ? "endDateISO" : "startDateISO",
            guidance: "Correct the requested dates using actual observations."
        )
        return LuminaReActObservation(toolName: schema.name, status: .failed, summary: reason, output: result.output, errorMessage: reason)
    }

    private func object(_ value: LuminaJSONValue?) throws -> [String: LuminaJSONValue] {
        let value = try XCTUnwrap(value)
        guard case let .object(object) = value else {
            throw NSError(domain: "Expected structured feedback object", code: 1)
        }
        return object
    }

    private func observedClockTrace() -> LuminaReActTrace {
        LuminaReActTrace(steps: [.observation(timeObservation(output: [
            "iso8601": .string("2026-09-08T06:15:20+08:00"),
            "timeZoneIdentifier": .string("Asia/Shanghai")
        ]))])
    }

    private func singleTarget(
        _ request: String,
        now: Date,
        calendar: Calendar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> LuminaStrictScheduleTarget {
        let targets = LuminaTemporalParser.strictScheduleTargets(request, now: now, calendar: calendar)
        XCTAssertEqual(targets.count, 1, request, file: file, line: line)
        return try XCTUnwrap(targets.first, request, file: file, line: line)
    }

    private func date(_ iso: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: iso), iso)
    }

    private func calendar(_ identifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: identifier))
        return calendar
    }

    private func timeObservation(
        toolName: String = "device.current_time",
        status: LuminaToolResultStatus = .succeeded,
        output: [String: LuminaJSONValue]
    ) -> LuminaReActObservation {
        LuminaReActObservation(toolName: toolName, status: status, summary: "Current time", output: output)
    }
}
