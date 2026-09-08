import Foundation
import LuminaAgentRuntime
@testable import LuminaAppCore
import XCTest

final class ToolOutcomeCheckedStepGeneratorTests: XCTestCase {
    private let tools = [
        LuminaToolSchema(name: "reminder.create", description: "Create reminder", parameters: [], sideEffect: .systemWrite),
        LuminaToolSchema(name: "calendar.create", description: "Create calendar event", parameters: [], sideEffect: .systemWrite)
    ]

    func testResultWithoutPendingWritesPassesThroughWithoutAnotherGeneration() async throws {
        let result = LuminaReActStep.result("日程已创建")
        let model = OutcomeTestGenerator(outputs: [.step(result)])
        let wrapper = LuminaToolOutcomeCheckedStepGenerator(underlying: model)
        let context = context(steps: [.observation(.init(toolName: "calendar.create", status: .succeeded, summary: "created"))])

        let actual = try await wrapper.nextStep(context: context)
        let contexts = await model.contexts()

        XCTAssertEqual(actual, result)
        XCTAssertEqual(contexts.count, 1)
    }

    func testCorrectableFailureGetsOneHostCorrectionAndModelAction() async throws {
        let suggested: LuminaJSONValue = .object([
            "toolName": .string("reminder.create"),
            "arguments": .object(["title": .string("吃早餐"), "dueDateISO": .string("2026-09-09T08:00:00+08:00")])
        ])
        let action = LuminaReActStep.action(thought: "Correct reminder date", call: .init(toolName: "reminder.create", arguments: [
            "title": .string("吃早餐"), "dueDateISO": .string("2026-09-09T08:00:00+08:00")
        ]))
        let model = OutcomeTestGenerator(outputs: [.step(.result("已完成")), .step(action)])
        let initial = context(steps: [.observation(failure(suggestedCall: suggested))])

        let actual = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: initial)
        let contexts = await model.contexts()
        let corrected = try XCTUnwrap(contexts.last)
        let section = try XCTUnwrap(corrected.loadedContext.sections.last)

        XCTAssertEqual(actual, action)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertEqual(initial.loadedContext.sections.count, 1)
        XCTAssertEqual(contexts[0].loadedContext, initial.loadedContext)
        XCTAssertEqual(corrected.loadedContext.sections.dropLast(), initial.loadedContext.sections[...])
        XCTAssertEqual(corrected.trace, initial.trace)
        XCTAssertEqual(corrected.request, initial.request)
        XCTAssertEqual(corrected.availableTools, initial.availableTools)
        XCTAssertEqual(corrected.remainingToolCalls, initial.remainingToolCalls)
        XCTAssertEqual(corrected.iteration, initial.iteration)
        XCTAssertEqual(section.id, "app.tool_outcome_correction")
        XCTAssertEqual(section.source, "lumina.host.tool_outcome_guard")
        XCTAssertTrue(section.content.contains("dueDateISO is in the past"))
        XCTAssertTrue(section.content.contains(LuminaToolPromptPolicy.json(suggested)))
        XCTAssertTrue(section.content.contains("Do not say these writes are completed"))
    }

    func testSecondResultThrowsOriginalIncompleteWriteReason() async throws {
        let model = OutcomeTestGenerator(outputs: [.step(.result("已完成")), .step(.result("都完成了"))])
        do {
            _ = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: context(steps: [.observation(failure())]))
            XCTFail("Expected an incomplete write failure")
        } catch let error as LuminaIncompleteToolWritesError {
            XCTAssertEqual(error.pendingFailures.map(\.toolName), ["reminder.create"])
            XCTAssertTrue(error.localizedDescription.contains("reminder.create"))
            XCTAssertTrue(error.localizedDescription.contains("dueDateISO is in the past"))
        }
        let contexts = await model.contexts()
        XCTAssertEqual(contexts.count, 2)
    }

    func testDifferentSuccessfulWriteDoesNotHideFailureAndIsNotRetried() async throws {
        let correctedAction = LuminaReActStep.action(thought: "Create missing reminder", call: .init(toolName: "reminder.create", arguments: [:]))
        let model = OutcomeTestGenerator(outputs: [.step(.result("提醒和日程都已完成")), .step(correctedAction)])
        let initial = context(steps: [
            .observation(failure()),
            .observation(.init(toolName: "calendar.create", status: .succeeded, summary: "calendar created"))
        ])

        let result = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: initial)
        let contexts = await model.contexts()
        let correction = try XCTUnwrap(contexts.last?.loadedContext.sections.last)

        XCTAssertEqual(result, correctedAction)
        XCTAssertEqual(contexts.count, 2)
        XCTAssertTrue(correction.summary.contains("reminder.create"))
        XCTAssertFalse(correction.summary.contains("calendar.create"))
        XCTAssertTrue(correction.content.contains("A different tool's success does not complete these operations"))
    }

    func testSuccessOfPreviouslyFailedToolClearsPendingWrite() async throws {
        let final = LuminaReActStep.result("提醒已成功创建")
        let model = OutcomeTestGenerator(outputs: [.step(final)])
        let result = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: context(steps: [
            .observation(failure()),
            .observation(.init(toolName: "reminder.create", status: .succeeded, summary: "reminder created"))
        ]))
        let contexts = await model.contexts()
        XCTAssertEqual(result, final)
        XCTAssertEqual(contexts.count, 1)
    }

    func testPermissionCancellationAndUncertainWriteDoNotTriggerModelRetry() async throws {
        let cases: [(LuminaToolResultStatus, String)] = [
            (.denied, "correct_arguments"), (.cancelled, "correct_arguments"),
            (.failed, "verify_before_retry"), (.failed, "request_permission"), (.failed, "stop")
        ]
        for (status, policy) in cases {
            let model = OutcomeTestGenerator(outputs: [.step(.result("已完成"))])
            let pending = failure(status: status, retryPolicy: policy, reason: "original permission or execution restriction")
            do {
                _ = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: context(steps: [.observation(pending)]))
                XCTFail("Expected \(status)/\(policy) to stop without retry")
            } catch let error as LuminaIncompleteToolWritesError {
                XCTAssertTrue(error.localizedDescription.contains("original permission or execution restriction"))
            }
            let contexts = await model.contexts()
            XCTAssertEqual(contexts.count, 1)
        }
    }

    func testUnderlyingCancellationPropagatesWithoutRetry() async throws {
        let model = OutcomeTestGenerator(outputs: [.cancelled])
        do {
            _ = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: context(steps: [.observation(failure())]))
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        let contexts = await model.contexts()
        XCTAssertEqual(contexts.count, 1)
    }

    func testInitialActionIsPassedToRuntimeWithoutParameterChanges() async throws {
        let action = LuminaReActStep.action(thought: "Model choice", call: .init(toolName: "reminder.create", arguments: ["unexpected": .bool(true)]))
        let model = OutcomeTestGenerator(outputs: [.step(action)])
        let result = try await LuminaToolOutcomeCheckedStepGenerator(underlying: model).nextStep(context: context(steps: [.observation(failure())]))
        let contexts = await model.contexts()
        XCTAssertEqual(result, action)
        XCTAssertEqual(contexts.count, 1)
    }

    private func failure(
        status: LuminaToolResultStatus = .failed,
        retryPolicy: String = "correct_arguments",
        reason: String = "dueDateISO is in the past",
        suggestedCall: LuminaJSONValue = .null
    ) -> LuminaReActObservation {
        .init(toolName: "reminder.create", status: status, summary: reason, output: [
            "failure": .object([
                "code": .string("invalid_date"), "reason": .string(reason),
                "retryPolicy": .string(retryPolicy), "suggestedCall": suggestedCall
            ])
        ], errorMessage: reason)
    }

    private func context(steps: [LuminaReActStep]) -> LuminaReActStepContext {
        .init(request: .init(text: "创建吃早餐的提醒和日历会议"), availableTools: tools, trace: .init(steps: steps),
              loadedContext: .init(sections: [.init(id: "existing", title: "Existing context", summary: "preserve", content: "preserve", source: "test")]),
              iteration: 3, remainingToolCalls: 4, maximumObservationCharacters: 2_000)
    }
}

private actor OutcomeTestGenerator: LuminaReActStepGenerator {
    enum Output: Sendable {
        case step(LuminaReActStep)
        case cancelled
    }
    private let outputs: [Output]
    private var receivedContexts: [LuminaReActStepContext] = []

    init(outputs: [Output]) { self.outputs = outputs }

    func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        receivedContexts.append(context)
        switch outputs[min(receivedContexts.count - 1, outputs.count - 1)] {
        case let .step(step): return step
        case .cancelled: throw CancellationError()
        }
    }

    func contexts() -> [LuminaReActStepContext] { receivedContexts }
}
