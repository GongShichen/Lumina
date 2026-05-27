import Foundation

enum LuminaSystemPermissionRequest {
    static func withTimeout(
        seconds: UInt64 = 15,
        operation: @escaping @Sendable () async throws -> Bool
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let gate = LuminaSystemPermissionResumeGate()
            Task {
                do {
                    let result = try await operation()
                    gate.resume(.success(result), continuation: continuation)
                } catch {
                    gate.resume(.failure(error), continuation: continuation)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                gate.resume(.failure(AppToolError.permissionDenied("系统权限请求没有及时返回。请在系统设置中检查权限后再试。")), continuation: continuation)
            }
        }
    }
}
