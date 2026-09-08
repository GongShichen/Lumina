import Foundation

/// Waits for a real system permission decision, while allowing the calling
/// tool to cancel even when the operating system request itself cannot cancel.
public enum LuminaPermissionDecisionAwaiter {
    public static func wait(
        operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        let gate = LuminaPermissionDecisionGate()
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            let granted = try await withCheckedThrowingContinuation { continuation in
                guard gate.install(continuation) else { return }
                let request = Task {
                    do {
                        try Task.checkCancellation()
                        gate.resolve(.success(try await operation()))
                    } catch {
                        gate.resolve(.failure(error))
                    }
                }
                gate.setRequest(request)
            }
            // Cancellation wins even if it raced with a successful OS callback.
            try Task.checkCancellation()
            return granted
        } onCancel: {
            gate.cancel()
        }
    }
}

private final class LuminaPermissionDecisionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Error>?
    private var result: Result<Bool, Error>?
    private var request: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Bool, Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    func setRequest(_ request: Task<Void, Never>) {
        lock.lock()
        let finished = result != nil
        if !finished { self.request = request }
        lock.unlock()
        // Handles cancellation before the child task was registered.
        if finished { request.cancel() }
    }

    func resolve(_ result: Result<Bool, Error>) {
        finish(result, cancelRequest: false)
    }

    func cancel() {
        finish(.failure(CancellationError()), cancelRequest: true)
    }

    private func finish(_ result: Result<Bool, Error>, cancelRequest: Bool) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = self.continuation
        let request = self.request
        self.continuation = nil
        self.request = nil
        lock.unlock()
        if cancelRequest { request?.cancel() }
        continuation?.resume(with: result)
    }
}
