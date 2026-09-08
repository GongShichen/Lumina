import Foundation
@testable import LuminaModelRuntime
import XCTest

final class InferenceSerialGateCancellationTests: XCTestCase, @unchecked Sendable {
    func testCancelledQueuedGenerationNeverExecutes() async throws {
        let gate = LuminaModelInferenceSerialGate()
        let firstStarted = InferenceTestLatch()
        let releaseFirst = InferenceTestLatch()
        let queuedSubmitted = InferenceTestLatch()
        let recorder = InferenceTestRecorder()

        let first = Task {
            try await gate.enqueue {
                await recorder.begin("first")
                await firstStarted.signal()
                await releaseFirst.wait()
                await recorder.end("first")
                return "first"
            }
        }
        await firstStarted.wait()
        let queued = Task {
            await queuedSubmitted.signal()
            return try await gate.enqueue {
                await recorder.begin("cancelled")
                await recorder.end("cancelled")
                return "must not execute"
            }
        }
        await queuedSubmitted.wait()
        queued.cancel()
        await releaseFirst.signal()

        let firstResult = try await first.value
        XCTAssertEqual(firstResult, "first")
        await assertCancelled(queued)
        let events = await recorder.events
        XCTAssertEqual(events, ["first.start", "first.end"])
    }

    func testRunningGenerationCannotReturnSuccessWhenOperationIgnoresCancellation() async {
        let gate = LuminaModelInferenceSerialGate()
        let started = InferenceTestLatch()
        let release = InferenceTestLatch()
        let recorder = InferenceTestRecorder()
        let running = Task {
            try await gate.enqueue {
                await recorder.begin("running")
                await started.signal()
                // A checked continuation deliberately ignores Task cancellation,
                // as a synchronous native decoder can until its next abort check.
                await release.wait()
                await recorder.end("running")
                return "must not be returned"
            }
        }

        await started.wait()
        running.cancel()
        await release.signal()
        await assertCancelled(running)
        let events = await recorder.events
        XCTAssertEqual(events, ["running.start", "running.end"])
    }

    func testFollowingGenerationStaysSerializedAndRunsAfterCancellation() async throws {
        let gate = LuminaModelInferenceSerialGate()
        let firstStarted = InferenceTestLatch()
        let releaseFirst = InferenceTestLatch()
        let followingSubmitted = InferenceTestLatch()
        let recorder = InferenceTestRecorder()
        let first = Task {
            try await gate.enqueue {
                await recorder.begin("cancelled")
                await firstStarted.signal()
                await releaseFirst.wait()
                await recorder.end("cancelled")
                return "must not be returned"
            }
        }
        await firstStarted.wait()
        first.cancel()
        let following = Task {
            await followingSubmitted.signal()
            return try await gate.enqueue {
                await recorder.begin("following")
                await recorder.end("following")
                return "following result"
            }
        }
        await followingSubmitted.wait()
        await releaseFirst.signal()

        await assertCancelled(first)
        let followingResult = try await following.value
        XCTAssertEqual(followingResult, "following result")
        let events = await recorder.events
        let maximumActive = await recorder.maximumActive
        XCTAssertEqual(events, ["cancelled.start", "cancelled.end", "following.start", "following.end"])
        XCTAssertEqual(maximumActive, 1, "Cancellation must not release the queue while native work is still running.")
    }

    private func assertCancelled<T: Sendable>(
        _ task: Task<T, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected CancellationError rather than a successful generation.", file: file, line: line)
        } catch is CancellationError {
            // Expected cancellation reaches the original caller.
        } catch {
            XCTFail("Expected CancellationError, received \(error).", file: file, line: line)
        }
    }
}

private actor InferenceTestLatch {
    private var signalled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signalled = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private actor InferenceTestRecorder {
    private(set) var events: [String] = []
    private(set) var maximumActive = 0
    private var active = 0

    func begin(_ name: String) {
        active += 1
        maximumActive = max(maximumActive, active)
        events.append("\(name).start")
    }

    func end(_ name: String) {
        events.append("\(name).end")
        active -= 1
    }
}
