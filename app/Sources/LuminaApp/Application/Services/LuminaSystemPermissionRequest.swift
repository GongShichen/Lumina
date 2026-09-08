import Foundation
import LuminaAppCore

enum LuminaSystemPermissionRequest {
    static func awaitDecision(
        operation: @escaping @MainActor @Sendable () async throws -> Bool
    ) async throws -> Bool {
        try await LuminaPermissionTimingRecorder.shared.record {
            try await LuminaPermissionDecisionAwaiter.wait {
                try await requestOnMainActor(operation)
            }
        }
    }

    @MainActor
    private static func requestOnMainActor(
        _ operation: @MainActor @Sendable () async throws -> Bool
    ) async throws -> Bool {
        // Cancellation may arrive while this request waits for the main actor.
        try Task.checkCancellation()
        return try await operation()
    }
}
