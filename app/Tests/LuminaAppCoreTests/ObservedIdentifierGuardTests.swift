import Foundation
import XCTest
import LuminaAgentRuntime
@testable import LuminaAppCore

final class ObservedIdentifierGuardTests: XCTestCase {
    func testRenameWithoutObservedIDSuggestsSearchingTheOriginalObjectName() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let arguments: [String: LuminaJSONValue] = ["id": .string("项目同步"), "title": .string("季度复盘")]
        let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: "把日程“项目同步”改名为“季度复盘”", trace: .init(),
            call: LuminaToolCall(toolName: update.name, arguments: arguments), availableTools: [update, search]
        ))
        XCTAssertEqual(failure.string("code"), "missing_observed_identifier")
        XCTAssertEqual(failure.string("retryPolicy"), "prerequisite")
        XCTAssertEqual(failure["arguments"], .object(arguments))
        XCTAssertEqual(failure["suggestedCall"], .object([
            "toolName": .string("calendar.search"), "arguments": .object(["query": .string("项目同步")])
        ]))
    }

    func testRenameDestinationDoesNotBecomeTheLookupQueryWhenTheOriginalIsUnknown() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        for request in ["改名为“季度复盘”", "把这个日程改名为“季度复盘”"] {
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: request, trace: .init(),
                call: LuminaToolCall(toolName: update.name, arguments: ["id": .string("季度复盘"), "title": .string("季度复盘")]),
                availableTools: [update, search]
            ))
            XCTAssertEqual(failure.string("code"), "missing_observed_identifier")
            XCTAssertEqual(failure["suggestedCall"], .null, request)
            let missing = try missingInformation(failure)
            XCTAssertFalse(missing.isEmpty, "The model needs to know which original object information is missing")
            XCTAssertTrue(missing.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
    }

    func testSuccessfulRegisteredSameDomainLookupSuppliesRealStructuredIdentifiers() {
        let update = mutationSchema("calendar.update")
        let identifier = "event-actual-42"
        let call = LuminaToolCall(toolName: update.name, arguments: ["id": .string(identifier), "title": .string("季度复盘")])
        let cases: [(String, [String: LuminaJSONValue])] = [
            ("calendar.search", ["items": .array([.object(["id": .string(identifier), "title": .string("项目同步")])])]),
            ("calendar.lookup", ["items": .array([.object(["identifier": .string(identifier), "title": .string("项目同步")])])]),
            ("calendar.list", ["events": .array([.object(["identifier": .string(identifier), "title": .string("项目同步")])])])
        ]
        for (toolName, output) in cases {
            let lookup = lookupSchema(toolName)
            let trace = trace(toolName: toolName, output: output)
            XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: "把日程“项目同步”改名为“季度复盘”", trace: trace,
                call: call, availableTools: [update, lookup]
            ), toolName)
        }
    }

    func testExplicitIDMarkersInSuccessfulLookupSummariesAreRecognized() {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let identifier = "event-actual-42"
        let call = LuminaToolCall(toolName: update.name, arguments: ["id": .string(identifier), "title": .string("季度复盘")])
        let traces = [
            trace(toolName: search.name, summary: "[id=event-actual-42] 项目同步 @ 明天八点"),
            trace(toolName: search.name, output: ["events": .array([.string("[id=event-actual-42] 项目同步 @ 明天八点")])])
        ]
        for trace in traces {
            XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: "把日程“项目同步”改名为“季度复盘”", trace: trace, call: call, availableTools: [update, search]
            ))
        }
    }

    func testFailedOtherDomainUnregisteredAndWriteResultsCannotAuthorizeAnID() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let reminderSearch = lookupSchema("reminder.search")
        let calendarCreate = mutationSchema("calendar.create")
        let output: [String: LuminaJSONValue] = ["items": .array([.object(["id": .string("event-actual-42"), "title": .string("项目同步")])])]
        let call = LuminaToolCall(toolName: update.name, arguments: ["id": .string("event-actual-42"), "title": .string("季度复盘")])
        let cases: [(String, LuminaReActTrace, [LuminaToolSchema])] = [
            ("failed lookup", trace(toolName: search.name, status: .failed, output: output), [update, search]),
            ("denied lookup", trace(toolName: search.name, status: .denied, output: output), [update, search]),
            ("other domain", trace(toolName: reminderSearch.name, output: output), [update, search, reminderSearch]),
            ("unregistered lookup", trace(toolName: "calendar.lookup", output: output), [update, search]),
            ("successful write", trace(toolName: calendarCreate.name, output: output), [update, search, calendarCreate])
        ]
        for (label, trace, tools) in cases {
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: "把日程“项目同步”改名为“季度复盘”", trace: trace, call: call, availableTools: tools
            ), label)
            XCTAssertEqual(failure.string("code"), "missing_observed_identifier", label)
        }
    }

    func testTitleAndQueryStringsDoNotMasqueradeAsAnObservedIdentifier() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let call = LuminaToolCall(toolName: update.name, arguments: ["id": .string("项目同步"), "title": .string("季度复盘")])
        let traces = [
            trace(toolName: search.name, output: ["items": .array([.object(["id": .string("event-actual-42"), "title": .string("项目同步")])])]),
            trace(toolName: search.name, output: ["items": .array([.object(["title": .string("项目同步")])])]),
            trace(toolName: search.name, output: ["query": .string("项目同步"), "items": .array([])]),
            trace(toolName: search.name, summary: "项目同步")
        ]
        for trace in traces {
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: "把日程“项目同步”改名为“季度复盘”", trace: trace, call: call, availableTools: [update, search]
            ))
            XCTAssertEqual(failure.string("code"), "missing_observed_identifier")
        }
    }

    func testUserProvidedFullUUIDOrExplicitIDCanBeUsedWithoutALookup() {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let cases = [
            ("把日程 8B2DD700-6F68-4C61-9DCC-1EFECF770322 改名为季度复盘", "8B2DD700-6F68-4C61-9DCC-1EFECF770322"),
            ("把日程 id: event-actual-42 改名为季度复盘", "event-actual-42")
        ]
        for (request, identifier) in cases {
            XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: request, trace: .init(),
                call: LuminaToolCall(toolName: update.name, arguments: ["id": .string(identifier), "title": .string("季度复盘")]),
                availableTools: [update, search]
            ), request)
        }
    }

    func testExplicitUserIdentifierDoesNotAuthorizeAnotherOrPartialID() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let cases = [
            ("把日程 8B2DD700-6F68-4C61-9DCC-1EFECF770322 改名为季度复盘", "C82CD802-CFB4-4B5E-B015-771C07BA45A4"),
            ("把日程 id: event-actual-42 改名为季度复盘", "event-actual-4"),
            ("把日程“event-actual-42”改名为“季度复盘”", "event-actual-42")
        ]
        for (request, identifier) in cases {
            let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: request, trace: .init(),
                call: LuminaToolCall(toolName: update.name, arguments: ["id": .string(identifier), "title": .string("季度复盘")]),
                availableTools: [update, search]
            ), request)
            XCTAssertEqual(failure.string("code"), "missing_observed_identifier")
        }
    }

    func testIDDependentWritesAcrossDomainsRequireTheirOwnObservedObjects() throws {
        let cases = [
            ("calendar.update", "calendar.search", "日程"),
            ("calendar.delete", "calendar.search", "日程"),
            ("reminder.complete", "reminder.list", "提醒"),
            ("reminder.update", "reminder.list", "提醒"),
            ("reminder.delete", "reminder.list", "提醒"),
            ("ledger.update", "ledger.search", "账目"),
            ("ledger.delete", "ledger.search", "账目"),
            ("subscription.remove", "subscription.list", "订阅")
        ]
        for (writeName, lookupName, objectName) in cases {
            let write = mutationSchema(writeName)
            let lookup = lookupSchema(lookupName)
            let call = LuminaToolCall(toolName: write.name, arguments: ["id": .string("actual-object-42")])
            let request = "修改\(objectName)“项目同步”"
            let missing = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: request, trace: .init(), call: call, availableTools: [write, lookup]
            ), writeName)
            XCTAssertEqual(missing.string("code"), "missing_observed_identifier", writeName)
            let output: [String: LuminaJSONValue] = ["items": .array([.object(["identifier": .string("actual-object-42"), "title": .string("项目同步")])])]
            XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
                request: request, trace: trace(toolName: lookup.name, output: output), call: call, availableTools: [write, lookup]
            ), writeName)
        }
    }

    func testNoRegisteredLookupCannotProduceAnInventedSuggestedCall() throws {
        let update = mutationSchema("calendar.update")
        let failure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: "把日程“项目同步”改名为“季度复盘”", trace: .init(),
            call: LuminaToolCall(toolName: update.name, arguments: ["id": .string("项目同步"), "title": .string("季度复盘")]),
            availableTools: [update, lookupSchema("reminder.search")]
        ))
        XCTAssertEqual(failure["suggestedCall"], .null)
        XCTAssertFalse(try missingInformation(failure).isEmpty)
    }

    func testRuntimePreflightMissingIDKeepsDiagnosisAndAddsTheOriginalNameLookup() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let reason = "Missing required parameter id."
        let feedback = LuminaToolFailureFeedback.payload(
            code: "validation_failed", reason: reason, toolName: update.name,
            arguments: ["title": .string("季度复盘")], schema: update,
            fieldErrors: [.object(["field": .string("id"), "reason": .string(reason)])],
            retryPolicy: "correct_arguments", guidance: "Supply id."
        )
        let observation = LuminaReActObservation(toolName: update.name, status: .failed, summary: reason, output: ["failure": feedback])
        let enriched = LuminaToolFailureFeedback.enrichedObservation(
            observation, arguments: ["title": .string("季度复盘")], availableTools: [update, search],
            request: "把日程“项目同步”改名为“季度复盘”", trace: .init()
        )
        guard case let .object(failure) = enriched.output["failure"] else { return XCTFail("Expected structured feedback") }
        XCTAssertEqual(failure.string("code"), "validation_failed")
        XCTAssertEqual(failure.string("reason"), reason)
        XCTAssertEqual(failure["suggestedCall"], .object([
            "toolName": .string(search.name), "arguments": .object(["query": .string("项目同步")])
        ]))
    }

    func testStructuredEmptyResultsOverrideSummaryAndFallbackOnlyUsesLeadingIDMarkers() throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let request = "把日程“项目同步”改名为“季度复盘”"
        let actualCall = LuminaToolCall(toolName: update.name, arguments: ["id": .string("event-actual-42"), "title": .string("季度复盘")])
        let emptyStructuredTrace = trace(
            toolName: search.name, summary: "[id=event-actual-42] 项目同步", output: ["items": .array([])]
        )
        XCTAssertNotNil(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: request, trace: emptyStructuredTrace, call: actualCall, availableTools: [update, search]
        ), "An empty structured lookup result cannot be overridden by a stale summary")

        let fallbackTrace = trace(toolName: search.name, summary: "- [id=event-actual-42] 项目同步 [id=event-fake-99]")
        XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: request, trace: fallbackTrace, call: actualCall, availableTools: [update, search]
        ))
        let fakeCall = LuminaToolCall(toolName: update.name, arguments: ["id": .string("event-fake-99"), "title": .string("季度复盘")])
        let fakeFailure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: request, trace: fallbackTrace, call: fakeCall, availableTools: [update, search]
        ))
        XCTAssertEqual(fakeFailure.string("code"), "missing_observed_identifier", "A marker embedded in an object title is not an ID source")
    }

    func testOptionalContactIDStillRequiresLookupWhileExplicitMemoryBulkDeleteKeepsItsPath() throws {
        let contactsUpdate = LuminaToolSchema(
            name: "contacts.update", description: "Update a contact.", parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "Contact identifier.", required: false),
                LuminaToolParameterSchema(name: "name", type: .string, description: "Contact name.", required: false)
            ], sideEffect: .systemWrite
        )
        let contactsSearch = lookupSchema("contacts.search")
        let contactFailure = try XCTUnwrap(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: "修改联系人“张三”", trace: .init(),
            call: LuminaToolCall(toolName: contactsUpdate.name, arguments: ["name": .string("张三")]),
            availableTools: [contactsUpdate, contactsSearch]
        ))
        XCTAssertEqual(contactFailure.string("code"), "missing_observed_identifier")
        XCTAssertEqual(contactFailure.string("retryPolicy"), "prerequisite")

        let memoryDelete = LuminaToolSchema(
            name: "memory.delete", description: "Delete one memory or all memories.", parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "Memory identifier.", required: false),
                LuminaToolParameterSchema(name: "all", type: .bool, description: "Delete all memories.", required: false)
            ], sideEffect: .systemWrite
        )
        XCTAssertNil(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: "删除全部记忆", trace: .init(),
            call: LuminaToolCall(toolName: memoryDelete.name, arguments: ["all": .bool(true)]), availableTools: [memoryDelete]
        ), "The identifier guard must preserve the existing explicit bulk-operation path")
        XCTAssertNotNil(LuminaToolFailureFeedback.missingObservedIdentifier(
            request: "删除这条记忆", trace: .init(),
            call: LuminaToolCall(toolName: memoryDelete.name, arguments: ["all": .bool(false)]), availableTools: [memoryDelete]
        ), "Only explicit all=true can use the no-ID bulk exception")
    }

    func testBeforeToolRejectsMissingObservedIDAsCorrectableValidation() async throws {
        let update = mutationSchema("calendar.update")
        let search = lookupSchema("calendar.search")
        let call = LuminaToolCall(toolName: update.name, arguments: ["title": .string("季度复盘")])
        let context = LuminaAgentRuntimeHookContext(
            request: LuminaAgentRequest(text: "把日程“项目同步”改名为“季度复盘”"),
            availableTools: [update, search], toolCall: call
        )
        let directives = try await LuminaToolRecoveryRuntimePolicy().handle(event: .beforeTool, context: context)
        XCTAssertEqual(directives.count, 1)
        guard case let .rejectToolCallForValidation(reason, failure) = directives.first else {
            return XCTFail("The runtime must reject the write before execution and return correction feedback")
        }
        XCTAssertFalse(reason.isEmpty)
        XCTAssertEqual(failure.string("code"), "missing_observed_identifier")
        XCTAssertEqual(failure.string("retryPolicy"), "prerequisite")
        XCTAssertEqual(failure["suggestedCall"], .object([
            "toolName": .string("calendar.search"), "arguments": .object(["query": .string("项目同步")])
        ]))
    }

    private func mutationSchema(_ name: String) -> LuminaToolSchema {
        LuminaToolSchema(
            name: name, description: "Update the identified object.",
            parameters: [
                LuminaToolParameterSchema(name: "id", type: .string, description: "The object's actual identifier."),
                LuminaToolParameterSchema(name: "title", type: .string, description: "Optional replacement title.", required: false)
            ], sideEffect: .systemWrite
        )
    }

    private func lookupSchema(_ name: String) -> LuminaToolSchema {
        LuminaToolSchema(
            name: name, description: "Find existing objects and return their actual identifiers.",
            parameters: [LuminaToolParameterSchema(name: "query", type: .string, description: "Original object name.", required: false)],
            sideEffect: .readOnly
        )
    }

    private func trace(
        toolName: String,
        status: LuminaToolResultStatus = .succeeded,
        summary: String = "Lookup completed",
        output: [String: LuminaJSONValue] = [:]
    ) -> LuminaReActTrace {
        LuminaReActTrace(steps: [.observation(LuminaReActObservation(toolName: toolName, status: status, summary: summary, output: output))])
    }

    private func missingInformation(_ failure: [String: LuminaJSONValue]) throws -> [String] {
        let value = try XCTUnwrap(failure["missingInformation"])
        guard case let .array(values) = value else { throw NSError(domain: "Expected missing information array", code: 1) }
        return try values.map { try XCTUnwrap($0.stringValue) }
    }
}
