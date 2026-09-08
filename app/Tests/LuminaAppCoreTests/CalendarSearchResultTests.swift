import Foundation
import LuminaAgentRuntime
@testable import LuminaAppCore
import XCTest

final class CalendarSearchResultTests: XCTestCase {
    func testSearchReturnsRealIdentifierDatesAndActualQueryRange() async throws {
        let start = date("2026-09-09T07:00:00+08:00")
        let event = LuminaCalendarEvent(title: "项目同步", startDate: start, endDate: start.addingTimeInterval(1_800))
        let tool = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore(events: [event]))
        let result = try await tool.call(arguments: [
            "query": .string("项目"),
            "startDateISO": .string("2026-09-09T00:00:00+08:00"),
            "endDateISO": .string("2026-09-10T00:00:00+08:00")
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(result.status, .succeeded)
        let items = try items(result)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.string("id"), event.id.uuidString)
        XCTAssertEqual(item.string("identifier"), event.id.uuidString)
        XCTAssertEqual(item.string("title"), event.title)
        XCTAssertEqual(item.string("startDateISO").flatMap(LuminaToolFailureFeedback.parseDate), event.startDate)
        XCTAssertEqual(item.string("endDateISO").flatMap(LuminaToolFailureFeedback.parseDate), event.endDate)
        XCTAssertEqual(item.string("timeZone"), Calendar.current.timeZone.identifier)
        XCTAssertEqual(result.output.number("count"), 1)
        XCTAssertEqual(result.output.number("matchedCount"), 1)
        XCTAssertEqual(result.output.bool("truncated"), false)
        let range = try object(result.output["queryRange"])
        XCTAssertEqual(range.string("startDateISO").flatMap(LuminaToolFailureFeedback.parseDate), date("2026-09-09T00:00:00+08:00"))
        XCTAssertEqual(range.string("endDateISO").flatMap(LuminaToolFailureFeedback.parseDate), date("2026-09-10T00:00:00+08:00"))
        guard case let .array(summaries) = result.output["events"] else { return XCTFail("Legacy events are missing") }
        XCTAssertTrue(summaries.first?.stringValue?.contains(event.id.uuidString) == true)
        let executed = try object(result.output["executedArguments"])
        XCTAssertEqual(executed.string("query"), "项目")
        XCTAssertEqual(executed.number("limit"), 5)
    }

    func testTimeRangeFiltersBeforeLimitAndIncludesOverlappingEvents() async throws {
        let start = date("2026-09-09T00:00:00+08:00")
        let end = start.addingTimeInterval(86_400)
        let overlapping = LuminaCalendarEvent(title: "目标跨日", startDate: start.addingTimeInterval(-600), endDate: start.addingTimeInterval(600))
        let instant = LuminaCalendarEvent(title: "目标开始时刻", startDate: start)
        let matching = LuminaCalendarEvent(title: "目标下午", startDate: start.addingTimeInterval(3_600), endDate: start.addingTimeInterval(5_400))
        let store = LuminaVolatileCalendarStore(events: [
            LuminaCalendarEvent(title: "目标过去", startDate: start.addingTimeInterval(-7_200), endDate: start),
            LuminaCalendarEvent(title: "目标结束边界", startDate: end),
            LuminaCalendarEvent(title: "无关事件", startDate: start.addingTimeInterval(300)),
            matching, instant, overlapping
        ])
        let result = try await LuminaCalendarSearchTool(store: store).call(arguments: [
            "query": .string("目标"), "limit": .number(2),
            "startDateISO": .string("2026-09-09T00:00:00+08:00"),
            "endDateISO": .string("2026-09-10T00:00:00+08:00")
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(try items(result).compactMap { $0.string("id") }, [overlapping.id.uuidString, instant.id.uuidString])
        XCTAssertEqual(result.output.number("matchedCount"), 3)
        XCTAssertEqual(result.output.number("count"), 2)
        XCTAssertEqual(result.output.bool("truncated"), true)
    }

    func testDefaultRangeMatchesUpcomingThirtyDaysAndKeepsUnknownEndNull() async throws {
        let now = Date()
        let upcoming = LuminaCalendarEvent(title: "近期事件", startDate: now.addingTimeInterval(86_400))
        let result = try await LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore(events: [
            LuminaCalendarEvent(title: "过去事件", startDate: now.addingTimeInterval(-86_400)),
            upcoming,
            LuminaCalendarEvent(title: "很远事件", startDate: now.addingTimeInterval(40 * 86_400))
        ])).call(arguments: [:], cancellation: LuminaCancellationToken())
        let item = try XCTUnwrap(try items(result).first)

        XCTAssertEqual(item.string("id"), upcoming.id.uuidString)
        XCTAssertEqual(item["endDateISO"], .null)
        let range = try object(result.output["queryRange"])
        let actualStart = try XCTUnwrap(range.string("startDateISO").flatMap(LuminaToolFailureFeedback.parseDate))
        let actualEnd = try XCTUnwrap(range.string("endDateISO").flatMap(LuminaToolFailureFeedback.parseDate))
        XCTAssertEqual(actualStart.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 2)
        XCTAssertEqual(actualEnd, Calendar.current.date(byAdding: .day, value: 30, to: actualStart))
    }

    func testInvalidDateRangeReturnsExplicitValidationCorrection() async throws {
        let tool = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore())
        for arguments: [String: LuminaJSONValue] in [
            ["startDateISO": .string("tomorrow")],
            ["startDateISO": .string("2026-09-09T07:00:00")],
            ["endDateISO": .string("")],
            ["endDateISO": .number(123)],
            ["startDateISO": .string("2026-09-09T07:00:00Z"), "endDateISO": .string("2026-09-09T07:00:00Z")],
            ["startDateISO": .string("2026-09-09T07:00:00Z"), "endDateISO": .string("2026-09-09T06:00:00Z")]
        ] {
            let result = try await tool.call(arguments: arguments, cancellation: LuminaCancellationToken())
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.validationFailed, true)
            let failure = try object(result.output["failure"])
            XCTAssertTrue(["invalid_date", "invalid_date_range"].contains(failure.string("code") ?? ""))
            XCTAssertEqual(failure.string("retryPolicy"), "correct_arguments")
            XCTAssertEqual(try object(failure["toolSchema"]).string("name"), "calendar.search")
            XCTAssertFalse(failure.string("guidance")?.isEmpty ?? true)
        }
    }

    func testInvalidLimitsReturnValidationFeedbackInsteadOfTrappingOrTruncating() async throws {
        let tool = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore())
        for limit: LuminaJSONValue in [.number(-1), .number(0), .number(1.5), .number(101), .number(1e300), .string("5")] {
            let result = try await tool.call(arguments: ["limit": limit], cancellation: LuminaCancellationToken())
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(result.validationFailed, true)
            let failure = try object(result.output["failure"])
            XCTAssertEqual(failure.string("code"), "invalid_parameters")
            XCTAssertTrue(failure.string("reason")?.contains("1 to 100") == true)
        }
    }

    func testSharedResultUsesCalendarTimeZoneAndExplicitOffset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let now = date("2026-09-09T07:00:00+08:00")
        let schema = LuminaCalendarSearchTool(store: LuminaVolatileCalendarStore()).schema
        guard case let .valid(parameters) = LuminaCalendarSearchParameters.resolve(arguments: [:], schema: schema, now: now, calendar: calendar) else {
            return XCTFail("Expected valid defaults")
        }
        let item = try object(parameters.item(identifier: "actual-store-id", title: "同步", startDate: now, endDate: now.addingTimeInterval(1_800)))

        XCTAssertEqual(item.string("startDateISO"), "2026-09-09T07:00:00+08:00")
        XCTAssertEqual(item.string("endDateISO"), "2026-09-09T07:30:00+08:00")
        XCTAssertEqual(item.string("timeZone"), "Asia/Shanghai")
        XCTAssertEqual(parameters.end, calendar.date(byAdding: .day, value: 30, to: now))
    }

    private func date(_ value: String) -> Date { LuminaToolFailureFeedback.parseDate(value)! }

    private func object(_ value: LuminaJSONValue?) throws -> [String: LuminaJSONValue] {
        guard case let .object(object) = value else { throw CalendarSearchTestError.expectedObject }
        return object
    }

    private func items(_ result: LuminaToolResult) throws -> [[String: LuminaJSONValue]] {
        guard case let .array(items) = result.output["items"] else { throw CalendarSearchTestError.expectedItems }
        return try items.map { try object($0) }
    }
}

private enum CalendarSearchTestError: Error {
    case expectedObject
    case expectedItems
}
