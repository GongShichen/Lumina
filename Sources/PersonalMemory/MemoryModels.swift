import Foundation

public struct MemoryDocument: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var source: MemorySource
    public var title: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var sensitivity: MemorySensitivity
    public var metadata: [String: String]

    public init(
        id: UUID = UUID(),
        source: MemorySource,
        title: String,
        body: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sensitivity: MemorySensitivity = .normal,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sensitivity = sensitivity
        self.metadata = metadata
    }
}

public struct MemorySource: Codable, Hashable, Sendable {
    public var kind: MemorySourceKind
    public var identifier: String

    public init(kind: MemorySourceKind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }
}

public enum MemorySourceKind: String, Codable, Sendable {
    case appNote
    case calendar
    case reminder
    case ledger
    case subscription
    case imported
}

public enum MemorySensitivity: String, Codable, Comparable, Sendable {
    case low
    case normal
    case sensitive
    case privateData

    public static func < (lhs: MemorySensitivity, rhs: MemorySensitivity) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: 0
        case .normal: 1
        case .sensitive: 2
        case .privateData: 3
        }
    }
}

public struct MemoryChunk: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var documentID: UUID
    public var source: MemorySource
    public var title: String
    public var text: String
    public var summary: String
    public var createdAt: Date
    public var sensitivity: MemorySensitivity
    public var metadata: [String: String]
    public var embedding: [Float]?

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        source: MemorySource,
        title: String,
        text: String,
        summary: String,
        createdAt: Date,
        sensitivity: MemorySensitivity,
        metadata: [String: String],
        embedding: [Float]? = nil
    ) {
        self.id = id
        self.documentID = documentID
        self.source = source
        self.title = title
        self.text = text
        self.summary = summary
        self.createdAt = createdAt
        self.sensitivity = sensitivity
        self.metadata = metadata
        self.embedding = embedding
    }
}

public struct MemorySearchQuery: Sendable {
    public var text: String
    public var limit: Int
    public var sourceKinds: Set<MemorySourceKind>?
    public var since: Date?
    public var until: Date?
    public var maximumSensitivity: MemorySensitivity

    public init(
        text: String,
        limit: Int = 5,
        sourceKinds: Set<MemorySourceKind>? = nil,
        since: Date? = nil,
        until: Date? = nil,
        maximumSensitivity: MemorySensitivity = .privateData
    ) {
        self.text = text
        self.limit = limit
        self.sourceKinds = sourceKinds
        self.since = since
        self.until = until
        self.maximumSensitivity = maximumSensitivity
    }
}

public struct MemorySearchResult: Codable, Hashable, Sendable {
    public var chunk: MemoryChunk
    public var score: Float
    public var matchedBy: MemoryMatchKind

    public init(chunk: MemoryChunk, score: Float, matchedBy: MemoryMatchKind) {
        self.chunk = chunk
        self.score = score
        self.matchedBy = matchedBy
    }
}

public enum MemoryMatchKind: String, Codable, Sendable {
    case vector
    case keyword
    case metadata
}
