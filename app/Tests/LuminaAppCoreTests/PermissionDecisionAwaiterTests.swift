import Foundation
@testable import LuminaAppCore
import XCTest

final class PermissionDecisionAwaiterTests: XCTestCase, @unchecked Sendable {
    func testWaitsForRealApprovalBeyondFormerDeadline() async throws {
        let system = PermissionTestSystem()
        let result = Task {
            try await LuminaPermissionDecisionAwaiter.wait { await system.request() }
        }
        await system.waitUntilRequested()

        // Advance a virtual system clock, without sleeping for the old 15 seconds.
        // The only event that may finish the permission request is its decision.
        await system.advance(by: 600)
        let pending = await system.hasPendingDecision
        let elapsed = await system.elapsedSeconds
        XCTAssertTrue(pending)
        XCTAssertGreaterThan(elapsed, 15)

        await system.decide(true)
        let granted = try await result.value
        XCTAssertTrue(granted)
    }

    func testDenialRemainsAnActualFalseDecision() async throws {
        let system = PermissionTestSystem()
        let result = Task {
            try await LuminaPermissionDecisionAwaiter.wait { await system.request() }
        }
        await system.waitUntilRequested()
        await system.decide(false)
        let granted = try await result.value
        XCTAssertFalse(granted)
    }

    func testCancelReturnsBeforeSystemDecisionAndLateApprovalCannotWrite() async {
        let system = PermissionTestSystem()
        let completed = expectation(description: "Cancellation returns while system permission remains pending")
        let result = Task {
            defer { completed.fulfill() }
            let granted = try await LuminaPermissionDecisionAwaiter.wait { await system.request() }
            try Task.checkCancellation()
            if granted { await system.write() }
            return granted
        }
        await system.waitUntilRequested()
        result.cancel()
        await fulfillment(of: [completed], timeout: 1)

        // A real OS sheet may outlive the cancelled tool. This callback must not
        // resume the caller twice, turn cancellation into success, or write data.
        await system.decide(true)
        await assertCancelled(result)
        let writes = await system.writeCount
        XCTAssertEqual(writes, 0)
    }

    func testAlreadyCancelledCallerNeverStartsPermissionRequest() async {
        let system = PermissionTestSystem()
        let start = PermissionTestLatch()
        let result = Task {
            await start.wait()
            return try await LuminaPermissionDecisionAwaiter.wait { await system.request() }
        }
        result.cancel()
        await start.signal()
        await assertCancelled(result)
        let requests = await system.requestCount
        XCTAssertEqual(requests, 0)
    }

    func testSystemErrorReachesCallerUnchanged() async {
        do {
            _ = try await LuminaPermissionDecisionAwaiter.wait { throw PermissionTestError.unavailable }
            XCTFail("Expected the operating system error")
        } catch PermissionTestError.unavailable {
            // Failure is not rewritten as permission denied.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertCancelled(_ task: Task<Bool, Error>) async {
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Cancellation is distinct from the user denying permission.
        } catch {
            XCTFail("Expected CancellationError, received \(error)")
        }
    }
}

private enum PermissionTestError: Error { case unavailable }

private actor PermissionTestSystem {
    private var decision: CheckedContinuation<Bool, Never>?
    private var requested: [CheckedContinuation<Void, Never>] = []
    private(set) var elapsedSeconds = 0
    private(set) var requestCount = 0
    private(set) var writeCount = 0
    var hasPendingDecision: Bool { decision != nil }

    func request() async -> Bool {
        requestCount += 1
        return await withCheckedContinuation { continuation in
            decision = continuation
            let waiters = requested
            requested.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async {
        if requestCount > 0 { return }
        await withCheckedContinuation { requested.append($0) }
    }

    func advance(by seconds: Int) { elapsedSeconds += seconds }

    func decide(_ granted: Bool) {
        let continuation = decision
        decision = nil
        continuation?.resume(returning: granted)
    }

    func write() { writeCount += 1 }
}

private actor PermissionTestLatch {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func signal() {
        signalled = true
        waiter?.resume()
        waiter = nil
    }
}
