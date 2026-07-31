import Foundation

public protocol LuminaKnowledgeRepository: Sendable {
    func loadImportedBases() async throws -> [LuminaKnowledgeBaseSnapshot]
    func saveImportedBase(
        _ snapshot: LuminaKnowledgeBaseSnapshot,
        sourceFiles: [String: Data]
    ) async throws
    func removeImportedBase(id: String) async throws
    func loadBundledCache(id: String, version: String) async throws -> LuminaKnowledgeBaseSnapshot?
    func saveBundledCache(_ snapshot: LuminaKnowledgeBaseSnapshot) async throws
    func loadBM25CacheData(for snapshot: LuminaKnowledgeBaseSnapshot) async throws -> Data?
    func loadPreferences() async throws -> [String: LuminaKnowledgeBasePreferences]
    func savePreferences(_ preferences: [String: LuminaKnowledgeBasePreferences]) async throws
}

public actor LuminaFileKnowledgeRepository: LuminaKnowledgeRepository {
    private let rootURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) {
        self.rootURL = rootURL
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func loadImportedBases() async throws -> [LuminaKnowledgeBaseSnapshot] {
        let importedURL = rootURL.appendingPathComponent("Imported", isDirectory: true)
        guard FileManager.default.fileExists(atPath: importedURL.path) else { return [] }
        let baseURLs = try FileManager.default.contentsOfDirectory(
            at: importedURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return baseURLs.map { baseURL in
            let snapshotURL = baseURL.appendingPathComponent("chunks.json")
            guard let data = try? Data(contentsOf: snapshotURL),
                  let snapshot = try? decoder.decode(LuminaKnowledgeBaseSnapshot.self, from: data)
            else {
                return failedImportedSnapshot(
                    id: baseURL.lastPathComponent,
                    reason: "chunks.json 无法读取或已损坏"
                )
            }
            guard snapshot.schemaVersion == 1 else {
                return failedImportedSnapshot(
                    id: snapshot.descriptor.id,
                    reason: "不支持 schema \(snapshot.schemaVersion)"
                )
            }
            // The BM25 file is only a derived acceleration cache. A write failure
            // must not make otherwise valid chunks unavailable to local search.
            try? ensureBM25Cache(for: snapshot, at: baseURL)
            return snapshot
        }
    }

    public func saveImportedBase(
        _ snapshot: LuminaKnowledgeBaseSnapshot,
        sourceFiles: [String: Data] = [:]
    ) async throws {
        try Task.checkCancellation()
        let importedURL = rootURL.appendingPathComponent("Imported", isDirectory: true)
        let baseURL = importedURL.appendingPathComponent(snapshot.descriptor.id, isDirectory: true)
        let isInitialImport = !FileManager.default.fileExists(atPath: baseURL.path)
        let writeURL = isInitialImport
            ? importedURL.appendingPathComponent(
                ".\(snapshot.descriptor.id).importing-\(UUID().uuidString)",
                isDirectory: true
            )
            : baseURL
        let documentsURL = writeURL.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)

        do {
            for (storedFileName, data) in sourceFiles {
                if isInitialImport { try Task.checkCancellation() }
                let destination = documentsURL.appendingPathComponent(storedFileName)
                try data.write(to: destination, options: .atomic)
            }

            let validNames = Set(snapshot.documents.map(\.storedFileName))
            if let existing = try? FileManager.default.contentsOfDirectory(
                at: documentsURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) {
                for fileURL in existing where !validNames.contains(fileURL.lastPathComponent) {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            }

            if isInitialImport { try Task.checkCancellation() }
            try write(snapshot, to: writeURL.appendingPathComponent("chunks.json"))
            try write(snapshot.descriptor, to: writeURL.appendingPathComponent("manifest.json"))
            try writeBM25Cache(for: snapshot, at: writeURL)
            if isInitialImport {
                try Task.checkCancellation()
                try FileManager.default.moveItem(at: writeURL, to: baseURL)
            }
        } catch {
            if isInitialImport {
                try? FileManager.default.removeItem(at: writeURL)
            }
            throw error
        }
    }

    public func removeImportedBase(id: String) async throws {
        let baseURL = rootURL
            .appendingPathComponent("Imported", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return }
        try FileManager.default.removeItem(at: baseURL)
    }

    public func loadBundledCache(id: String, version: String) async throws -> LuminaKnowledgeBaseSnapshot? {
        let url = bundledCacheURL(id: id, version: version).appendingPathComponent("chunks.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? decoder.decode(LuminaKnowledgeBaseSnapshot.self, from: data)
        else {
            return nil
        }
        guard snapshot.schemaVersion == 1,
              snapshot.descriptor.id == id,
              snapshot.descriptor.version == version
        else { return nil }
        try? ensureBM25Cache(
            for: snapshot,
            at: bundledCacheURL(id: id, version: version)
        )
        return snapshot
    }

    public func saveBundledCache(_ snapshot: LuminaKnowledgeBaseSnapshot) async throws {
        let cacheURL = bundledCacheURL(
            id: snapshot.descriptor.id,
            version: snapshot.descriptor.version
        )
        try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
        try write(snapshot, to: cacheURL.appendingPathComponent("chunks.json"))
        try writeBM25Cache(for: snapshot, at: cacheURL)
    }

    public func loadBM25CacheData(
        for snapshot: LuminaKnowledgeBaseSnapshot
    ) async throws -> Data? {
        let baseURL: URL
        if snapshot.descriptor.origin == .bundled {
            baseURL = bundledCacheURL(
                id: snapshot.descriptor.id,
                version: snapshot.descriptor.version
            )
        } else {
            baseURL = rootURL
                .appendingPathComponent("Imported", isDirectory: true)
                .appendingPathComponent(snapshot.descriptor.id, isDirectory: true)
        }
        let url = baseURL.appendingPathComponent("bm25-index-v1.plist")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func loadPreferences() async throws -> [String: LuminaKnowledgeBasePreferences] {
        let url = rootURL.appendingPathComponent("catalog.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
        return try decoder.decode(
            [String: LuminaKnowledgeBasePreferences].self,
            from: Data(contentsOf: url)
        )
    }

    public func savePreferences(_ preferences: [String: LuminaKnowledgeBasePreferences]) async throws {
        try write(preferences, to: rootURL.appendingPathComponent("catalog.json"))
    }

    private func bundledCacheURL(id: String, version: String) -> URL {
        rootURL
            .appendingPathComponent("BundledCache", isDirectory: true)
            .appendingPathComponent(id, isDirectory: true)
            .appendingPathComponent(version, isDirectory: true)
    }

    private func failedImportedSnapshot(
        id: String,
        reason: String
    ) -> LuminaKnowledgeBaseSnapshot {
        LuminaKnowledgeBaseSnapshot(
            descriptor: LuminaKnowledgeBaseDescriptor(
                id: id,
                title: id,
                summary: "用户知识库加载失败",
                version: "unknown",
                origin: .userImported,
                enabled: false,
                remoteAccess: .localOnly,
                indexStatus: .failed,
                failureReason: reason
            ),
            documents: [],
            chunks: []
        )
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func ensureBM25Cache(
        for snapshot: LuminaKnowledgeBaseSnapshot,
        at baseURL: URL
    ) throws {
        let url = baseURL.appendingPathComponent("bm25-index-v1.plist")
        let cachedData = try? Data(contentsOf: url)
        let cache = cachedData.flatMap {
            try? PropertyListDecoder().decode(LuminaBM25IndexCache.self, from: $0)
        }
        var validationIndex = LuminaBM25Index<String>()
        if let cache, validationIndex.merge(
            cache: cache,
            expectedGeneration: LuminaKnowledgeIndexGeneration.value(for: snapshot),
            expectedDocumentIDs: Set(snapshot.chunks.map(\.id))
        ) {
            return
        }
        try writeBM25Cache(for: snapshot, at: baseURL)
    }

    private func writeBM25Cache(
        for snapshot: LuminaKnowledgeBaseSnapshot,
        at baseURL: URL
    ) throws {
        var index = LuminaBM25Index<String>()
        index.rebuild(snapshot.chunks.map(LuminaKnowledgeBM25Document.make))
        let cache = index.cache(
            indexGeneration: LuminaKnowledgeIndexGeneration.value(for: snapshot)
        )
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        try PropertyListEncoder().encode(cache)
            .write(to: baseURL.appendingPathComponent("bm25-index-v1.plist"), options: .atomic)
    }
}

public actor LuminaInMemoryKnowledgeRepository: LuminaKnowledgeRepository {
    private var imported: [String: LuminaKnowledgeBaseSnapshot]
    private var bundled: [String: LuminaKnowledgeBaseSnapshot] = [:]
    private var preferences: [String: LuminaKnowledgeBasePreferences] = [:]

    public init(imported: [LuminaKnowledgeBaseSnapshot] = []) {
        self.imported = Dictionary(uniqueKeysWithValues: imported.map { ($0.descriptor.id, $0) })
    }

    public func loadImportedBases() async throws -> [LuminaKnowledgeBaseSnapshot] {
        Array(imported.values)
    }

    public func saveImportedBase(
        _ snapshot: LuminaKnowledgeBaseSnapshot,
        sourceFiles: [String: Data]
    ) async throws {
        imported[snapshot.descriptor.id] = snapshot
    }

    public func removeImportedBase(id: String) async throws {
        imported[id] = nil
    }

    public func loadBundledCache(id: String, version: String) async throws -> LuminaKnowledgeBaseSnapshot? {
        bundled["\(id)@\(version)"]
    }

    public func saveBundledCache(_ snapshot: LuminaKnowledgeBaseSnapshot) async throws {
        bundled["\(snapshot.descriptor.id)@\(snapshot.descriptor.version)"] = snapshot
    }

    public func loadBM25CacheData(
        for snapshot: LuminaKnowledgeBaseSnapshot
    ) async throws -> Data? {
        nil
    }

    public func loadPreferences() async throws -> [String: LuminaKnowledgeBasePreferences] {
        preferences
    }

    public func savePreferences(_ preferences: [String: LuminaKnowledgeBasePreferences]) async throws {
        self.preferences = preferences
    }
}

enum LuminaKnowledgeBM25Document {
    static func make(_ chunk: LuminaKnowledgeChunk) -> LuminaBM25Document<String> {
        LuminaBM25Document(
            id: chunk.id,
            title: chunk.title,
            tags: chunk.tags
                + [chunk.locator.heading].compactMap { $0 }
                + Array(chunk.metadata.values),
            body: chunk.text
        )
    }
}

enum LuminaKnowledgeIndexGeneration {
    static func value(for snapshot: LuminaKnowledgeBaseSnapshot) -> String {
        LuminaKnowledgeStableHash.string(
            snapshot.chunks
                .map { "\($0.id):\($0.contentHash):\($0.embedding?.count ?? 0)" }
                .joined(separator: "|")
        )
    }
}
