import Foundation

public struct MemorySnapshot: Codable, Hashable, Sendable {
    public var chunks: [MemoryChunk]
    public var documentIndex: [UUID: [UUID]]

    public init(chunks: [MemoryChunk], documentIndex: [UUID: [UUID]]) {
        self.chunks = chunks
        self.documentIndex = documentIndex
    }
}

public protocol MemoryRepository: Sendable {
    func load() async throws -> MemorySnapshot?
    func save(_ snapshot: MemorySnapshot) async throws
}

public actor InMemoryMemoryRepository: MemoryRepository {
    private var snapshot: MemorySnapshot?

    public init(snapshot: MemorySnapshot? = nil) {
        self.snapshot = snapshot
    }

    public func load() async throws -> MemorySnapshot? {
        snapshot
    }

    public func save(_ snapshot: MemorySnapshot) async throws {
        self.snapshot = snapshot
    }
}

public actor JSONMemoryRepository: MemoryRepository {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func load() async throws -> MemorySnapshot? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(MemorySnapshot.self, from: data)
    }

    public func save(_ snapshot: MemorySnapshot) async throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: .atomic)
    }
}

