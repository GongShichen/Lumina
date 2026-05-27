import Foundation

final class LuminaPermissionTimingRecorder: @unchecked Sendable {
    static let shared = LuminaPermissionTimingRecorder()

    private let lock = NSLock()
    private var nextEventID = 0
    private var events: [(id: Int, milliseconds: Double)] = []

    private init() {}

    func mark() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return nextEventID
    }

    func milliseconds(after mark: Int) -> Double {
        lock.lock()
        defer { lock.unlock() }
        return events
            .filter { $0.id > mark }
            .map(\.milliseconds)
            .reduce(0, +)
    }

    func record<T>(_ operation: () async throws -> T) async throws -> T {
        let start = ContinuousClock.now
        defer { append(milliseconds: Self.milliseconds(since: start)) }
        return try await operation()
    }

    func recordValue<T>(_ operation: () async -> T) async -> T {
        let start = ContinuousClock.now
        defer { append(milliseconds: Self.milliseconds(since: start)) }
        return await operation()
    }

    @MainActor
    func recordMainActorValue<T>(_ operation: () async -> T) async -> T {
        let start = ContinuousClock.now
        defer { append(milliseconds: Self.milliseconds(since: start)) }
        return await operation()
    }

    private func append(milliseconds: Double) {
        lock.lock()
        nextEventID += 1
        events.append((id: nextEventID, milliseconds: milliseconds))
        if events.count > 2_000 {
            events.removeFirst(events.count - 2_000)
        }
        lock.unlock()
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}
