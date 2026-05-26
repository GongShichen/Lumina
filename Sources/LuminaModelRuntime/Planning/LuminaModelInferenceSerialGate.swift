import Foundation

actor LuminaModelInferenceSerialGate {
    private var tail: Task<Void, Never>?
    private var generation: UInt64 = 0

    func enqueue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let previous = tail
        generation &+= 1
        let currentGeneration = generation
        let resultTask = Task<T, Error> {
            await previous?.value
            try Task.checkCancellation()
            return try await operation()
        }
        tail = Task<Void, Never> {
            _ = try? await resultTask.value
        }

        do {
            let result = try await resultTask.value
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
