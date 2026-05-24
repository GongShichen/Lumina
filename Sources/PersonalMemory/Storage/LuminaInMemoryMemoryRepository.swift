import Foundation

public actor LuminaInMemoryMemoryRepository: LuminaMemoryRepository {
    private var snapshot: LuminaMemorySnapshot?

    public init(snapshot: LuminaMemorySnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() async throws -> LuminaMemorySnapshot? {
        snapshot
    }

    public func save(_ snapshot: LuminaMemorySnapshot) async throws {
        self.snapshot = snapshot
    }
}
