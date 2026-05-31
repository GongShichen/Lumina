import Foundation

public enum LuminaRuntimeCheckpointPolicy: String, Codable, Hashable, Sendable {
    case none
    case onPause
    case onStep
    case onExit
}

public enum LuminaRuntimeReplayMode: String, Codable, Hashable, Sendable {
    case live
    case modelOutputs
    case toolObservations
}

public struct LuminaRuntimeCheckpoint: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var sessionID: String
    public var runID: String
    public var requestID: UUID
    public var stepIndex: Int
    public var status: LuminaAgentRunStatus
    public var traceSummary: String
    public var runtimeState: [String: [String: LuminaJSONValue]]
    public var pending: LuminaJSONValue?
    public var budget: [String: LuminaJSONValue]
    public var lastObservation: LuminaReActObservation?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        sessionID: String,
        runID: String,
        requestID: UUID,
        stepIndex: Int,
        status: LuminaAgentRunStatus,
        traceSummary: String,
        runtimeState: [String: [String: LuminaJSONValue]] = [:],
        pending: LuminaJSONValue? = nil,
        budget: [String: LuminaJSONValue] = [:],
        lastObservation: LuminaReActObservation? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.sessionID = sessionID
        self.runID = runID
        self.requestID = requestID
        self.stepIndex = stepIndex
        self.status = status
        self.traceSummary = traceSummary
        self.runtimeState = runtimeState
        self.pending = pending
        self.budget = budget
        self.lastObservation = lastObservation
        self.createdAt = createdAt
    }
}

public protocol LuminaRuntimeSessionStore: Sendable {
    func save(_ checkpoint: LuminaRuntimeCheckpoint) async throws
    func load(id: String) async throws -> LuminaRuntimeCheckpoint?
    func list() async throws -> [LuminaRuntimeCheckpoint]
    func delete(id: String) async throws
}

public actor LuminaFileRuntimeSessionStore: LuminaRuntimeSessionStore {
    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(directory: URL) {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    public func save(_ checkpoint: LuminaRuntimeCheckpoint) async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(checkpoint)
        try data.write(to: url(for: checkpoint.id), options: [.atomic])
    }

    public func load(id: String) async throws -> LuminaRuntimeCheckpoint? {
        let checkpointURL = url(for: id)
        guard FileManager.default.fileExists(atPath: checkpointURL.path) else { return nil }
        let data = try Data(contentsOf: checkpointURL)
        return try decoder.decode(LuminaRuntimeCheckpoint.self, from: data)
    }

    public func list() async throws -> [LuminaRuntimeCheckpoint] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        let checkpoints = try urls.compactMap { url -> LuminaRuntimeCheckpoint? in
            let data = try Data(contentsOf: url)
            return try decoder.decode(LuminaRuntimeCheckpoint.self, from: data)
        }
        return checkpoints.sorted { $0.createdAt > $1.createdAt }
    }

    public func delete(id: String) async throws {
        let checkpointURL = url(for: id)
        if FileManager.default.fileExists(atPath: checkpointURL.path) {
            try FileManager.default.removeItem(at: checkpointURL)
        }
    }

    private func url(for id: String) -> URL {
        let safeID = id
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return directory.appendingPathComponent(safeID).appendingPathExtension("json")
    }
}
