import Foundation

public struct LuminaMemorySnapshot: Codable, Hashable, Sendable {
    public var chunks: [LuminaMemoryChunk]
    public var documentIndex: [UUID: [UUID]]

    public init(chunks: [LuminaMemoryChunk], documentIndex: [UUID: [UUID]]) {
        self.chunks = chunks
        self.documentIndex = documentIndex
    }
}
