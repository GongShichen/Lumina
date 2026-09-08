import Foundation
import LuminaAgentRuntime
import XCTest
@testable import LuminaAppCore

final class CalendarMutationValidationTests: XCTestCase {
    func testTitleCannotMasqueradeAsCalendarIdentifier() async throws {
        let (store, original) = fixture()
        let tool = try updateTool(store)
        let result = try await tool.call(arguments: ["id": .string(original.title), "title": .string("Changed")], cancellation: .init())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailed, true)
        let details = try failure(result)
        XCTAssertEqual(details.string("code"), "missing_identifier")
        XCTAssertEqual(details["suggestedCall"], .object(["toolName": .string("calendar.search"), "arguments": .object([:])]))
        let events = await store.allEvents()
        XCTAssertEqual(events, [original])
    }

    func testUnknownUUIDDoesNotWriteOrResolveByTitle() async throws {
        let (store, original) = fixture()
        let tool = try updateTool(store)
        let result = try await tool.call(arguments: ["id": .string(UUID().uuidString), "title": .string(original.title)], cancellation: .init())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailed, true)
        XCTAssertEqual(try failure(result).string("code"), "missing_identifier")
        let events = await store.allEvents()
        XCTAssertEqual(events, [original])
    }

    func testOmittedEndRejectsZeroDurationWithoutPartiallyUpdatingTitleOrStart() async throws {
        let (store, original) = fixture()
        let tool = try updateTool(store)
        let newStart = try XCTUnwrap(original.endDate)
        let result = try await tool.call(arguments: [
            "id": .string(original.id.uuidString), "title": .string("Changed"),
            "startDateISO": .string(iso(newStart))
        ], cancellation: .init())
        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.validationFailed, true)
        XCTAssertEqual(try failure(result).string("code"), "invalid_date_range")
        let events = await store.allEvents()
        XCTAssertEqual(events, [original])
    }

    func testKnownIDAndCompleteDateRangeUpdateTheSameEvent() async throws {
        let (store, original) = fixture()
        let tool = try updateTool(store)
        let start = original.startDate.addingTimeInterval(1_800)
        let end = start.addingTimeInterval(1_800)
        let arguments: [String: LuminaJSONValue] = [
            "id": .string(original.id.uuidString.lowercased()), "startDateISO": .string(iso(start)),
            "endDateISO": .string(iso(end)), "title": .string("Changed")
        ]
        let result = try await tool.call(arguments: arguments, cancellation: .init())
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertNil(result.validationFailed)
        XCTAssertEqual(result.output.string("id"), original.id.uuidString)
        XCTAssertEqual(result.output.string("startDateISO"), iso(start))
        XCTAssertEqual(result.output.string("endDateISO"), iso(end))
        XCTAssertEqual(result.output["executedArguments"], .object(arguments))
        let events = await store.allEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].id, original.id)
        XCTAssertEqual(events[0].title, "Changed")
        XCTAssertEqual(events[0].startDate, start)
        XCTAssertEqual(events[0].endDate, end)
    }

    func testOmittedDatesPreserveTheExistingRange() async throws {
        let (store, original) = fixture()
        let result = try await updateTool(store).call(arguments: ["id": .string(original.id.uuidString), "title": .string("Changed")], cancellation: .init())
        XCTAssertEqual(result.status, .succeeded)
        let events = await store.allEvents()
        XCTAssertEqual(events[0].startDate, original.startDate)
        XCTAssertEqual(events[0].endDate, original.endDate)
    }

    func testCalendarDeleteAlsoRefusesTitleFallback() async throws {
        let (store, original) = fixture()
        let tool = try XCTUnwrap(LuminaExtendedToolCatalog.pimTools(calendarStore: store).first { $0.schema.name == "calendar.delete" })
        let result = try await tool.call(arguments: ["id": .string(original.title)], cancellation: .init())
        XCTAssertEqual(result.status, .failed)
        let events = await store.allEvents()
        XCTAssertEqual(events, [original])
    }

    private func fixture() -> (LuminaVolatileCalendarStore, LuminaCalendarEvent) {
        let start = Date(timeIntervalSince1970: floor(Date().addingTimeInterval(86_400).timeIntervalSince1970))
        let event = LuminaCalendarEvent(title: "LuminaTest 项目同步", startDate: start, endDate: start.addingTimeInterval(1_800))
        return (LuminaVolatileCalendarStore(events: [event]), event)
    }

    private func updateTool(_ store: LuminaVolatileCalendarStore) throws -> LuminaConfiguredTool {
        try XCTUnwrap(LuminaExtendedToolCatalog.pimTools(calendarStore: store).first { $0.schema.name == "calendar.update" })
    }

    private func failure(_ result: LuminaToolResult) throws -> [String: LuminaJSONValue] {
        guard case let .object(value)? = result.output["failure"] else {
            XCTFail("Expected structured failure feedback")
            throw NSError(domain: "CalendarMutationValidationTests", code: 1)
        }
        return value
    }

    private func iso(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
}
