import Foundation

public protocol LuminaMemoryRepository: Sendable {
    func load() async throws -> LuminaMemorySnapshot?
    func save(_ snapshot: LuminaMemorySnapshot) async throws
}
