import Foundation
import LuminaAgentRuntimeCore
import XCTest

final class BatchExecutionSafetyTests: XCTestCase {
    func testBatchStopsBeforeSecondWriteWhenOnlyOneToolCallRemains() throws {
        let run = try execute(maximumToolCalls: 1, steps: [batch(["one", "two"])])

        XCTAssertEqual(run.calls.count, 1)
        XCTAssertEqual(parameters(run.calls.first)?["q"] as? String, "one")
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 1)
        XCTAssertEqual(run.snapshot["remainingToolCalls"] as? Int, 0)
        let stopped = try XCTUnwrap(run.events.first { $0["type"] as? String == "multi_tool_use_stopped" })
        XCTAssertEqual(payload(stopped)?["reason"] as? String, "tool_budget")
        XCTAssertEqual(payload(stopped)?["skipped_call_count"] as? Int, 1)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_did_execute" }.count, 1)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "multi_tool_use_stopped" }.count, 1)
    }

    func testCancellationFromFirstCallbackStopsRemainingBatchCallsWithoutBudgetMasking() throws {
        let run = try execute(maximumToolCalls: 5, steps: [batch(["one", "two"])], cancelAfterFirstCall: true)

        XCTAssertEqual(run.calls.count, 1)
        XCTAssertEqual(run.snapshot["status"] as? String, "cancelled")
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 1)
        XCTAssertEqual(run.snapshot["remainingToolCalls"] as? Int, 4)
        let stopped = try XCTUnwrap(run.events.first { $0["type"] as? String == "multi_tool_use_stopped" })
        XCTAssertEqual(payload(stopped)?["reason"] as? String, "cancelled")
        XCTAssertEqual(payload(stopped)?["skipped_call_count"] as? Int, 1)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_did_execute" }.count, 1)
    }

    func testCancellationDuringPermissionCallbackPreventsExecutionEvenWhenPermissionReturnsAllowed() throws {
        let run = try execute(maximumToolCalls: 5, steps: [batch(["one", "two"])], cancelDuringPermission: true)

        XCTAssertEqual(run.permissionCalls, 1)
        XCTAssertEqual(run.calls.count, 0)
        XCTAssertEqual(run.snapshot["status"] as? String, "cancelled")
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 1)
        XCTAssertFalse(run.audits.contains { $0["type"] as? String == "tool_did_execute" })
        XCTAssertEqual(run.events.filter { $0["type"] as? String == "tool_call_cancelled_before_execution" }.count, 1)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_call_cancelled_before_execution" }.count, 1)
    }

    func testReadOnlyBatchContinuesAfterFirstFailureWhenConfigured() throws {
        let run = try execute(maximumToolCalls: 5, steps: [batch(["one", "two"])],
                              readOnly: true, failFirstCall: true)

        XCTAssertEqual(run.calls.count, 2)
        XCTAssertEqual(run.calls.compactMap { parameters($0)?["q"] as? String }, ["one", "two"])
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 2)
        XCTAssertEqual(run.snapshot["remainingToolCalls"] as? Int, 3)
        XCTAssertEqual(run.events.filter { $0["type"] as? String == "multi_tool_use_call_failed" }.count, 1)
        XCTAssertFalse(run.events.contains { $0["type"] as? String == "multi_tool_use_stopped" })
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_did_execute" }.count, 2)
    }

    func testCallerKeyedDuplicateExecutesOnceButBothAttemptsConsumeBudget() throws {
        let run = try execute(maximumToolCalls: 5, steps: [batch(["one", "one"])], idempotencyPolicy: "caller_keyed")

        XCTAssertEqual(run.calls.count, 1)
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 2)
        XCTAssertEqual(run.snapshot["remainingToolCalls"] as? Int, 3)
        XCTAssertEqual(run.events.filter { $0["type"] as? String == "tool_call_budget_consumed" }.count, 2)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_did_execute" }.count, 1)
        XCTAssertTrue(run.events.contains { event in
            event["type"] as? String == "observation_created" && payload(event)?["replayed"] as? Bool == true
        })
    }

    func testSingleCallAndBatchShareTheSameToolBudget() throws {
        let single: [String: Any] = ["type": "tool_use", "thinking": "Write first.",
                                     "tool_name": "record.write", "parameters": ["q": "single"]]
        let run = try execute(maximumToolCalls: 2, steps: [single, batch(["batch-one", "batch-two"])])

        XCTAssertEqual(run.calls.compactMap { parameters($0)?["q"] as? String }, ["single", "batch-one"])
        XCTAssertEqual(run.snapshot["actionCount"] as? Int, 2)
        XCTAssertEqual(run.snapshot["remainingToolCalls"] as? Int, 0)
        XCTAssertEqual(run.audits.filter { $0["type"] as? String == "tool_did_execute" }.count, 2)
        let stopped = try XCTUnwrap(run.events.first { $0["type"] as? String == "multi_tool_use_stopped" })
        XCTAssertEqual(payload(stopped)?["reason"] as? String, "tool_budget")
    }

    private func batch(_ arguments: [String]) -> [String: Any] {
        ["type": "multi_tool_use", "thinking": "Perform the requested operations.",
         "tool_calls": arguments.map { ["tool_name": "record.write", "parameters": ["q": $0]] }]
    }

    private func parameters(_ call: [String: Any]?) -> [String: Any]? {
        (call?["parameters"] ?? call?["arguments"]) as? [String: Any]
    }

    private func payload(_ event: [String: Any]) -> [String: Any]? { event["payload"] as? [String: Any] }

    private func execute(maximumToolCalls: Int, steps: [[String: Any]], readOnly: Bool = false,
                         failFirstCall: Bool = false, cancelAfterFirstCall: Bool = false,
                         cancelDuringPermission: Bool = false,
                         idempotencyPolicy: String = "replay_identical") throws -> BatchSafetyRun {
        let state = BatchSafetyCallbackState()
        state.steps = try steps.map(batchSafetyEncode)
        state.failFirstCall = failFirstCall
        state.cancelAfterFirstCall = cancelAfterFirstCall
        state.cancelDuringPermission = cancelDuringPermission
        let configuration = """
        {"maxIterations":5,"maxToolCalls":\(maximumToolCalls),"contextWindowTokens":12000,"maxOutputTokens":4096,"reservedOutputTokens":256,"maxObservationCharacters":1500,"toolResultTokenBudget":1024,"compactThresholdTokens":1800,"maxCompactFailures":3,"maxReasoningSteps":3,"maxReplayObservations":4,"stopOnToolFailure":false,"yoloMode":\(!cancelDuringPermission),"multiToolUseEnabled":true,"continueReadOnlyMultiToolFailures":true}
        """
        let runtime = try XCTUnwrap(LuminaAgentRuntimeCreate(configuration))
        state.runtime = runtime
        let context = Unmanaged.passRetained(state).toOpaque()
        defer {
            LuminaAgentRuntimeDestroy(runtime)
            Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).release()
        }
        LuminaAgentRuntimeSetModelCallback(runtime, batchSafetyModelCallback, context)
        LuminaAgentRuntimeSetToolCallback(runtime, batchSafetyToolCallback, context)
        LuminaAgentRuntimeSetPermissionCallback(runtime, batchSafetyPermissionCallback, context)
        LuminaAgentRuntimeSetEventCallback(runtime, batchSafetyEventCallback, context)
        LuminaAgentRuntimeSetAuditCallback(runtime, batchSafetyAuditCallback, context)
        let schema = try batchSafetyEncode([
            "name": "record.write", "description": "A mock record operation.",
            "sideEffect": readOnly ? "readOnly" : "appLocalWrite", "readOnly": readOnly,
            "idempotencyPolicy": idempotencyPolicy,
            "parameters": [["name": "q", "type": "string", "required": true]]
        ])
        let registered = LuminaAgentRuntimeRegisterToolSchema(runtime, schema)
        LuminaAgentRuntimeReleaseString(registered)
        let result = try XCTUnwrap(LuminaAgentRuntimeRun(runtime, #"{"id":"batch-safety-request","text":"Perform the specified mock operations."}"#))
        defer { LuminaAgentRuntimeReleaseString(result) }
        let snapshot = try batchSafetyDecode(String(cString: result))
        return BatchSafetyRun(snapshot: snapshot, calls: try state.calls.map(batchSafetyDecode),
                              events: try state.events.map(batchSafetyDecode), audits: try state.audits.map(batchSafetyDecode),
                              permissionCalls: state.permissionCalls)
    }
}

private struct BatchSafetyRun {
    var snapshot: [String: Any]
    var calls: [[String: Any]]
    var events: [[String: Any]]
    var audits: [[String: Any]]
    var permissionCalls: Int
}

private final class BatchSafetyCallbackState {
    var runtime: OpaquePointer?
    var steps: [String] = []
    var modelCalls = 0
    var calls: [String] = []
    var events: [String] = []
    var audits: [String] = []
    var failFirstCall = false
    var cancelAfterFirstCall = false
    var cancelDuringPermission = false
    var permissionCalls = 0
}

private let batchSafetyModelCallback: LuminaAgentModelCallback = { _, context in
    guard let context else { return nil }
    let state = Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).takeUnretainedValue()
    let index = state.modelCalls
    state.modelCalls += 1
    return strdup(index < state.steps.count ? state.steps[index] : #"{"type":"result","thinking":"Done.","content":"done"}"#)
}

private let batchSafetyToolCallback: LuminaAgentToolCallback = { call, context in
    guard let context, let call else { return nil }
    let state = Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).takeUnretainedValue()
    state.calls.append(String(cString: call))
    if state.calls.count == 1 {
        if state.cancelAfterFirstCall, let runtime = state.runtime {
            LuminaAgentRuntimeReleaseString(LuminaAgentRuntimeCancel(runtime, "batch-safety-request"))
        }
        if state.failFirstCall {
            return strdup(#"{"status":"failed","content":"","errorMessage":"Mock read failed."}"#)
        }
    }
    return strdup(#"{"status":"succeeded","content":"Mock operation succeeded.","output":{"id":"mock-record"}}"#)
}

private let batchSafetyPermissionCallback: LuminaAgentPermissionCallback = { _, context in
    guard let context else { return nil }
    let state = Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).takeUnretainedValue()
    state.permissionCalls += 1
    if state.cancelDuringPermission, let runtime = state.runtime {
        LuminaAgentRuntimeReleaseString(LuminaAgentRuntimeCancel(runtime, "batch-safety-request"))
    }
    return strdup(#"{"decision":"allowed"}"#)
}

private let batchSafetyEventCallback: LuminaAgentEventCallback = { event, context in
    guard let context, let event else { return }
    Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).takeUnretainedValue().events.append(String(cString: event))
}

private let batchSafetyAuditCallback: LuminaAgentAuditCallback = { audit, context in
    guard let context, let audit else { return }
    Unmanaged<BatchSafetyCallbackState>.fromOpaque(context).takeUnretainedValue().audits.append(String(cString: audit))
}

private func batchSafetyEncode(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

private func batchSafetyDecode(_ json: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}
