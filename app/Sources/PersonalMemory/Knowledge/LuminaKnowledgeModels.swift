import Foundation

public enum LuminaKnowledgeBaseOrigin: String, Codable, Sendable {
    case bundled
    case userImported
}

public enum LuminaKnowledgeRemoteAccess: String, Codable, Sendable {
    case localOnly
    case allowRemote
}

public enum LuminaKnowledgeSearchDestination: String, Codable, Sendable {
    case local
    case remote
}

public enum LuminaKnowledgeIndexStatus: String, Codable, Sendable {
    case notIndexed
    case indexing
    case ready
    case failed
}

public enum LuminaKnowledgeImportPhase: String, Codable, Sendable {
    case copying
    case extracting
    case indexingBM25
    case readyForSearch
    case embedding
    case complete
    case failed
}

public enum LuminaKnowledgeMatchKind: String, Codable, Sendable {
    case bm25
    case vector
    case hybrid
}

public struct LuminaKnowledgeBaseDescriptor: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    public var version: String
    public var origin: LuminaKnowledgeBaseOrigin
    public var enabled: Bool
    public var remoteAccess: LuminaKnowledgeRemoteAccess
    public var indexStatus: LuminaKnowledgeIndexStatus
    public var failureReason: String?
    public var documentCount: Int
    public var chunkCount: Int
    public var embeddedChunkCount: Int
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        title: String,
        summary: String,
        version: String,
        origin: LuminaKnowledgeBaseOrigin,
        enabled: Bool,
        remoteAccess: LuminaKnowledgeRemoteAccess,
        indexStatus: LuminaKnowledgeIndexStatus = .notIndexed,
        failureReason: String? = nil,
        documentCount: Int = 0,
        chunkCount: Int = 0,
        embeddedChunkCount: Int = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.version = version
        self.origin = origin
        self.enabled = enabled
        self.remoteAccess = remoteAccess
        self.indexStatus = indexStatus
        self.failureReason = failureReason
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.embeddedChunkCount = embeddedChunkCount
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct LuminaKnowledgeLocator: Codable, Hashable, Sendable {
    public var fileName: String
    public var heading: String?
    public var pageNumber: Int?
    public var characterStart: Int?
    public var characterEnd: Int?

    public init(
        fileName: String,
        heading: String? = nil,
        pageNumber: Int? = nil,
        characterStart: Int? = nil,
        characterEnd: Int? = nil
    ) {
        self.fileName = fileName
        self.heading = heading
        self.pageNumber = pageNumber
        self.characterStart = characterStart
        self.characterEnd = characterEnd
    }

    public var citation: String {
        var value = fileName
        if let pageNumber {
            value += " · p.\(pageNumber)"
        } else if let heading, !heading.isEmpty {
            value += " · \(heading)"
        }
        return value
    }
}

public struct LuminaKnowledgeDocument: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var knowledgeBaseID: String
    public var title: String
    public var fileName: String
    public var storedFileName: String
    public var mediaType: String
    public var contentHash: String
    public var importedAt: Date
    public var tags: [String]
    public var capabilityCategories: [String]
    public var pageCount: Int?
    public var characterCount: Int
    public var importStatus: LuminaKnowledgeImportPhase
    public var metadata: [String: String]

    public init(
        id: String,
        knowledgeBaseID: String,
        title: String,
        fileName: String,
        storedFileName: String,
        mediaType: String,
        contentHash: String,
        importedAt: Date = Date(),
        tags: [String] = [],
        capabilityCategories: [String] = [],
        pageCount: Int? = nil,
        characterCount: Int = 0,
        importStatus: LuminaKnowledgeImportPhase = .complete,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.knowledgeBaseID = knowledgeBaseID
        self.title = title
        self.fileName = fileName
        self.storedFileName = storedFileName
        self.mediaType = mediaType
        self.contentHash = contentHash
        self.importedAt = importedAt
        self.tags = tags
        self.capabilityCategories = capabilityCategories
        self.pageCount = pageCount
        self.characterCount = characterCount
        self.importStatus = importStatus
        self.metadata = metadata
    }
}

public struct LuminaKnowledgeChunk: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var knowledgeBaseID: String
    public var documentID: String
    public var ordinal: Int
    public var title: String
    public var text: String
    public var summary: String
    public var locator: LuminaKnowledgeLocator
    public var tags: [String]
    public var contentHash: String
    public var embedding: [Float]?
    public var metadata: [String: String]

    public init(
        id: String,
        knowledgeBaseID: String,
        documentID: String,
        ordinal: Int,
        title: String,
        text: String,
        summary: String,
        locator: LuminaKnowledgeLocator,
        tags: [String],
        contentHash: String,
        embedding: [Float]? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.knowledgeBaseID = knowledgeBaseID
        self.documentID = documentID
        self.ordinal = ordinal
        self.title = title
        self.text = text
        self.summary = summary
        self.locator = locator
        self.tags = tags
        self.contentHash = contentHash
        self.embedding = embedding
        self.metadata = metadata
    }
}

public struct LuminaKnowledgeSearchQuery: Hashable, Sendable {
    public var text: String
    public var knowledgeBaseIDs: Set<String>?
    public var limit: Int
    public var destination: LuminaKnowledgeSearchDestination
    public var includeDisabled: Bool
    public var availableCapabilityCategories: Set<String>?

    public init(
        text: String,
        knowledgeBaseIDs: Set<String>? = nil,
        limit: Int = 5,
        destination: LuminaKnowledgeSearchDestination = .local,
        includeDisabled: Bool = false,
        availableCapabilityCategories: Set<String>? = nil
    ) {
        self.text = text
        self.knowledgeBaseIDs = knowledgeBaseIDs
        self.limit = limit
        self.destination = destination
        self.includeDisabled = includeDisabled
        self.availableCapabilityCategories = availableCapabilityCategories
    }
}

public struct LuminaKnowledgeSearchResult: Codable, Hashable, Sendable {
    public var chunk: LuminaKnowledgeChunk
    public var score: Float
    public var matchedBy: LuminaKnowledgeMatchKind
    public var bm25Rank: Int?
    public var vectorRank: Int?

    public init(
        chunk: LuminaKnowledgeChunk,
        score: Float,
        matchedBy: LuminaKnowledgeMatchKind,
        bm25Rank: Int?,
        vectorRank: Int?
    ) {
        self.chunk = chunk
        self.score = score
        self.matchedBy = matchedBy
        self.bm25Rank = bm25Rank
        self.vectorRank = vectorRank
    }

    public var citation: String { chunk.locator.citation }
}

public struct LuminaKnowledgeSearchReport: Codable, Hashable, Sendable {
    public var results: [LuminaKnowledgeSearchResult]
    public var candidateCount: Int
    public var bm25CandidateCount: Int
    public var vectorCandidateCount: Int
    public var elapsedMilliseconds: Double
    public var cacheHit: Bool
    public var fallbackReason: String?

    public init(
        results: [LuminaKnowledgeSearchResult],
        candidateCount: Int,
        bm25CandidateCount: Int,
        vectorCandidateCount: Int,
        elapsedMilliseconds: Double,
        cacheHit: Bool,
        fallbackReason: String? = nil
    ) {
        self.results = results
        self.candidateCount = candidateCount
        self.bm25CandidateCount = bm25CandidateCount
        self.vectorCandidateCount = vectorCandidateCount
        self.elapsedMilliseconds = elapsedMilliseconds
        self.cacheHit = cacheHit
        self.fallbackReason = fallbackReason
    }
}

public struct LuminaKnowledgeStats: Codable, Hashable, Sendable {
    public var knowledgeBaseCount: Int
    public var documentCount: Int
    public var chunkCount: Int
    public var embeddedChunkCount: Int

    public init(knowledgeBaseCount: Int, documentCount: Int, chunkCount: Int, embeddedChunkCount: Int) {
        self.knowledgeBaseCount = knowledgeBaseCount
        self.documentCount = documentCount
        self.chunkCount = chunkCount
        self.embeddedChunkCount = embeddedChunkCount
    }

    public static let empty = LuminaKnowledgeStats(
        knowledgeBaseCount: 0,
        documentCount: 0,
        chunkCount: 0,
        embeddedChunkCount: 0
    )
}

public struct LuminaKnowledgeStoreConfiguration: Codable, Hashable, Sendable {
    public var cacheLimit: Int
    public var targetChunkCharacters: Int
    public var overlapCharacters: Int
    public var maximumFileBytes: Int
    public var maximumPDFPages: Int
    public var maximumDocumentsPerBase: Int
    public var maximumEnabledChunks: Int
    public var scheduleBackgroundEmbedding: Bool
    public var persistAfterEmbedding: Bool

    public init(
        cacheLimit: Int = 32,
        targetChunkCharacters: Int = 900,
        overlapCharacters: Int = 120,
        maximumFileBytes: Int = 25 * 1_024 * 1_024,
        maximumPDFPages: Int = 500,
        maximumDocumentsPerBase: Int = 200,
        maximumEnabledChunks: Int = 50_000,
        scheduleBackgroundEmbedding: Bool = true,
        persistAfterEmbedding: Bool = true
    ) {
        self.cacheLimit = cacheLimit
        self.targetChunkCharacters = targetChunkCharacters
        self.overlapCharacters = overlapCharacters
        self.maximumFileBytes = maximumFileBytes
        self.maximumPDFPages = maximumPDFPages
        self.maximumDocumentsPerBase = maximumDocumentsPerBase
        self.maximumEnabledChunks = maximumEnabledChunks
        self.scheduleBackgroundEmbedding = scheduleBackgroundEmbedding
        self.persistAfterEmbedding = persistAfterEmbedding
    }
}

public struct LuminaKnowledgeBaseSnapshot: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var descriptor: LuminaKnowledgeBaseDescriptor
    public var documents: [LuminaKnowledgeDocument]
    public var chunks: [LuminaKnowledgeChunk]

    public init(
        schemaVersion: Int = 1,
        descriptor: LuminaKnowledgeBaseDescriptor,
        documents: [LuminaKnowledgeDocument],
        chunks: [LuminaKnowledgeChunk]
    ) {
        self.schemaVersion = schemaVersion
        self.descriptor = descriptor
        self.documents = documents
        self.chunks = chunks
    }
}

public struct LuminaKnowledgeBasePreferences: Codable, Hashable, Sendable {
    public var enabled: Bool
    public var remoteAccess: LuminaKnowledgeRemoteAccess

    public init(enabled: Bool, remoteAccess: LuminaKnowledgeRemoteAccess) {
        self.enabled = enabled
        self.remoteAccess = remoteAccess
    }
}

public struct LuminaKnowledgeBundledManifest: Codable, Hashable, Sendable {
    public struct Document: Codable, Hashable, Sendable {
        public var id: String
        public var path: String
        public var title: String
        public var tags: [String]
        public var capabilityCategories: [String]

        enum CodingKeys: String, CodingKey {
            case id, path, title, tags
            case capabilityCategories = "capability_categories"
        }
    }

    public var schemaVersion: Int
    public var id: String
    public var version: String
    public var title: String
    public var summary: String
    public var defaultEnabled: Bool
    public var remoteAccess: LuminaKnowledgeRemoteAccess
    public var documents: [Document]

    enum CodingKeys: String, CodingKey {
        case id, version, title, summary, documents
        case schemaVersion = "schema_version"
        case defaultEnabled = "default_enabled"
        case remoteAccess = "remote_access"
    }
}
