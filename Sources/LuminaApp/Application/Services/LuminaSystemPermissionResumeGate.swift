import Foundation

final class LuminaSystemPermissionResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func resume(
        _ result: Result<Bool, Error>,
        continuation: CheckedContinuation<Bool, Error>
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return }
        didResume = true
        continuation.resume(with: result)
    }
}
