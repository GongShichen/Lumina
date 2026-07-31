import Foundation

struct LuminaBM25Document<ID: Hashable & Sendable>: Sendable {
    var id: ID
    var title: String
    var tags: [String]
    var body: String
}

struct LuminaBM25Hit<ID: Hashable & Sendable>: Sendable {
    var id: ID
    var score: Float
}

struct LuminaBM25IndexCache: Codable, Sendable {
    struct Posting: Codable, Sendable {
        var documentID: String
        var frequency: Float
    }

    var schemaVersion: Int
    var tokenizerVersion: Int
    var documentCount: Int
    var averageDocumentLength: Float
    var indexGeneration: String
    var documentLengths: [String: Float]
    var documentFrequencies: [String: Int]
    var postings: [String: [Posting]]
}

struct LuminaBM25Index<ID: Hashable & Sendable>: Sendable {
    static var tokenizerVersion: Int { 1 }

    private struct IndexedDocument: Sendable {
        var termFrequencies: [String: Float]
        var length: Float
    }

    private var documents: [ID: IndexedDocument] = [:]
    private var postings: [String: [ID: Float]] = [:]
    private var totalDocumentLength: Float = 0

    var count: Int { documents.count }

    mutating func removeAll(keepingCapacity: Bool = false) {
        documents.removeAll(keepingCapacity: keepingCapacity)
        postings.removeAll(keepingCapacity: keepingCapacity)
        totalDocumentLength = 0
    }

    mutating func rebuild(_ values: [LuminaBM25Document<ID>]) {
        removeAll(keepingCapacity: true)
        for value in values {
            upsert(value)
        }
    }

    mutating func upsert(_ value: LuminaBM25Document<ID>) {
        remove(id: value.id)
        var frequencies: [String: Float] = [:]
        addTerms(LuminaSearchTokenizer.tokens(in: value.title), weight: 2.0, to: &frequencies)
        addTerms(LuminaSearchTokenizer.tokens(in: value.tags.joined(separator: " ")), weight: 1.5, to: &frequencies)
        addTerms(LuminaSearchTokenizer.tokens(in: value.body), weight: 1.0, to: &frequencies)
        let length = max(1, frequencies.values.reduce(0, +))
        documents[value.id] = IndexedDocument(termFrequencies: frequencies, length: length)
        totalDocumentLength += length
        for (term, frequency) in frequencies {
            postings[term, default: [:]][value.id] = frequency
        }
    }

    mutating func remove(id: ID) {
        guard let document = documents.removeValue(forKey: id) else { return }
        totalDocumentLength -= document.length
        for term in document.termFrequencies.keys {
            postings[term]?[id] = nil
            if postings[term]?.isEmpty == true {
                postings[term] = nil
            }
        }
    }

    func search(
        _ query: String,
        allowedIDs: Set<ID>? = nil,
        limit: Int
    ) -> [LuminaBM25Hit<ID>] {
        let queryTerms = Set(LuminaSearchTokenizer.tokens(in: query))
        let eligibleIDs = allowedIDs.map { $0.intersection(documents.keys) }
            ?? Set(documents.keys)
        guard !queryTerms.isEmpty, !eligibleIDs.isEmpty else { return [] }
        let documentCount = Float(eligibleIDs.count)
        let eligibleDocumentLength = eligibleIDs.reduce(Float.zero) {
            $0 + (documents[$1]?.length ?? 0)
        }
        let averageLength = max(1, eligibleDocumentLength / documentCount)
        let k1: Float = 1.2
        let b: Float = 0.75
        var scores: [ID: Float] = [:]

        for term in queryTerms {
            guard let termPostings = postings[term], !termPostings.isEmpty else { continue }
            let documentFrequency = Float(termPostings.keys.lazy.filter(eligibleIDs.contains).count)
            guard documentFrequency > 0 else { continue }
            let idf = log(1 + ((documentCount - documentFrequency + 0.5) / (documentFrequency + 0.5)))
            for (id, frequency) in termPostings {
                guard eligibleIDs.contains(id) else { continue }
                guard let document = documents[id] else { continue }
                let normalization = frequency + k1 * (1 - b + b * document.length / averageLength)
                scores[id, default: 0] += idf * (frequency * (k1 + 1)) / max(0.0001, normalization)
            }
        }

        return scores
            .map { LuminaBM25Hit(id: $0.key, score: $0.value) }
            .sorted {
                if $0.score == $1.score {
                    return String(describing: $0.id) < String(describing: $1.id)
                }
                return $0.score > $1.score
            }
            .prefix(max(0, limit))
            .map { $0 }
    }

    private func addTerms(_ terms: [String], weight: Float, to frequencies: inout [String: Float]) {
        for term in terms {
            frequencies[term, default: 0] += weight
        }
    }
}

extension LuminaBM25Index where ID == String {
    func cache(indexGeneration: String) -> LuminaBM25IndexCache {
        let serializedPostings = postings.mapValues { values in
            values.map {
                LuminaBM25IndexCache.Posting(documentID: $0.key, frequency: $0.value)
            }
            .sorted { $0.documentID < $1.documentID }
        }
        return LuminaBM25IndexCache(
            schemaVersion: 1,
            tokenizerVersion: Self.tokenizerVersion,
            documentCount: documents.count,
            averageDocumentLength: documents.isEmpty
                ? 0
                : totalDocumentLength / Float(documents.count),
            indexGeneration: indexGeneration,
            documentLengths: documents.mapValues(\.length),
            documentFrequencies: serializedPostings.mapValues(\.count),
            postings: serializedPostings
        )
    }

    mutating func merge(
        cache: LuminaBM25IndexCache,
        expectedGeneration: String,
        expectedDocumentIDs: Set<String>
    ) -> Bool {
        guard cache.schemaVersion == 1,
              cache.tokenizerVersion == Self.tokenizerVersion,
              cache.indexGeneration == expectedGeneration,
              cache.documentCount == expectedDocumentIDs.count,
              Set(cache.documentLengths.keys) == expectedDocumentIDs,
              expectedDocumentIDs.isDisjoint(with: documents.keys)
        else { return false }

        var frequenciesByDocument: [String: [String: Float]] = [:]
        for (term, values) in cache.postings {
            guard cache.documentFrequencies[term] == values.count else { return false }
            for posting in values {
                guard expectedDocumentIDs.contains(posting.documentID),
                      posting.frequency.isFinite,
                      posting.frequency > 0
                else { return false }
                frequenciesByDocument[posting.documentID, default: [:]][term] = posting.frequency
            }
        }

        for id in expectedDocumentIDs {
            guard let length = cache.documentLengths[id],
                  length.isFinite,
                  length >= 1
            else { return false }
            documents[id] = IndexedDocument(
                termFrequencies: frequenciesByDocument[id] ?? [:],
                length: length
            )
            totalDocumentLength += length
        }
        for (term, values) in cache.postings {
            for posting in values {
                postings[term, default: [:]][posting.documentID] = posting.frequency
            }
        }
        return true
    }
}

enum LuminaSearchTokenizer {
    static func tokens(in input: String) -> [String] {
        let normalized = input
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        var tokens: [String] = []
        var wordScalars: [UnicodeScalar] = []
        var previousCJK: UnicodeScalar?

        func flushWord() {
            guard !wordScalars.isEmpty else { return }
            tokens.append(String(String.UnicodeScalarView(wordScalars)))
            wordScalars.removeAll(keepingCapacity: true)
        }

        for scalar in normalized.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                let current = String(scalar)
                tokens.append(current)
                if let previousCJK {
                    tokens.append(String(previousCJK) + current)
                }
                previousCJK = scalar
            } else if CharacterSet.alphanumerics.contains(scalar) {
                previousCJK = nil
                wordScalars.append(scalar)
            } else {
                flushWord()
                previousCJK = nil
            }
        }
        flushWord()
        return tokens
    }

    static func normalizedQuery(_ input: String) -> String {
        tokens(in: input).joined(separator: " ")
    }

    private static func isCJK(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F,
             0x3040...0x30FF,
             0xAC00...0xD7AF:
            true
        default:
            false
        }
    }
}

struct LuminaRRFHit<ID: Hashable & Sendable>: Sendable {
    var id: ID
    var score: Float
    var bm25Rank: Int?
    var vectorRank: Int?
}

enum LuminaReciprocalRankFusion {
    static func merge<ID: Hashable & Sendable>(
        bm25IDs: [ID],
        vectorIDs: [ID],
        limit: Int,
        rankConstant: Float = 60
    ) -> [LuminaRRFHit<ID>] {
        var values: [ID: LuminaRRFHit<ID>] = [:]
        for (offset, id) in bm25IDs.enumerated() {
            let rank = offset + 1
            values[id] = LuminaRRFHit(
                id: id,
                score: 1 / (rankConstant + Float(rank)),
                bm25Rank: rank,
                vectorRank: nil
            )
        }
        for (offset, id) in vectorIDs.enumerated() {
            let rank = offset + 1
            var value = values[id] ?? LuminaRRFHit(id: id, score: 0, bm25Rank: nil, vectorRank: nil)
            value.score += 1 / (rankConstant + Float(rank))
            value.vectorRank = rank
            values[id] = value
        }
        return values.values
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                if ($0.bm25Rank ?? .max) != ($1.bm25Rank ?? .max) {
                    return ($0.bm25Rank ?? .max) < ($1.bm25Rank ?? .max)
                }
                if ($0.vectorRank ?? .max) != ($1.vectorRank ?? .max) {
                    return ($0.vectorRank ?? .max) < ($1.vectorRank ?? .max)
                }
                return String(describing: $0.id) < String(describing: $1.id)
            }
            .prefix(max(0, limit))
            .map { $0 }
    }
}
