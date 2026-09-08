import Foundation

actor LuminaModelInferenceSerialGate {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        let previous = tail
        generation &+= 1
        let currentGeneration = generation
        let resultTask = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            let result = try await operation()
            try Task.checkCancellation()
            return result
        }
        tail = Task<Void, Never> {
            _ = try? await resultTask.value
        }

        do {
            let result = try await withTaskCancellationHandler {
                let value = try await resultTask.value
                try Task.checkCancellation()
                return value
            } onCancel: {
                resultTask.cancel()
            }
            if generation == currentGeneration {
                tail = nil
            }
            return result
        } catch {
            if generation == currentGeneration {
                tail = nil
            }
            throw error
        }
    }
}
