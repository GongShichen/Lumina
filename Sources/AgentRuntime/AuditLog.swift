import Foundation

public struct AuditRecord: Codable, Hashable, Sendable {
    public var id: UUID
    public var timestamp: Date
    public var requestID: UUID
    public var toolName: String
    public var schemaVersion: Int
    public var arguments: [String: JSONValue]
    public var permission: String
    public var confirmed: Bool
    public var resultStatus: ToolResultStatus
    public var outputSummary: String
    public var errorMessage: String?
    public var rollbackStatus: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        requestID: UUID,
        toolName: String,
        schemaVersion: Int,
        arguments: [String: JSONValue],
        permission: String,
        confirmed: Bool,
        resultStatus: ToolResultStatus,
        outputSummary: String,
        errorMessage: String? = nil,
        rollbackStatus: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.requestID = requestID
        self.toolName = toolName
        self.schemaVersion = schemaVersion
        self.arguments = arguments
        self.permission = permission
        self.confirmed = confirmed
        self.resultStatus = resultStatus
        self.outputSummary = outputSummary
        self.errorMessage = errorMessage
        self.rollbackStatus = rollbackStatus
    }
}

public protocol AuditLogger: Sendable {
    func append(_ record: AuditRecord) async
}

public actor InMemoryAuditLogger: AuditLogger {
    private var records: [AuditRecord] = []

    public init() {}

    public func append(_ record: AuditRecord) {
        records.append(record)
    }

    public func allRecords() -> [AuditRecord] {
        records
    }
}

public actor JSONLAuditLogger: AuditLogger {
    private let url: URL
    private let encoder: JSONEncoder

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func append(_ record: AuditRecord) async {
        do {
            let data = try encoder.encode(record)
            var line = data
            line.append(0x0A)
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
                try handle.close()
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try line.write(to: url, options: .atomic)
            }
        } catch {
            assertionFailure("Failed to append audit record: \(error)")
        }
    }
}

public enum AuditRedactor {
    public static func redact(arguments: [String: JSONValue], schema: ToolSchema) -> [String: JSONValue] {
        let sensitiveNames = Set(schema.parameters.filter(\.sensitive).map(\.name))
        let implicitSensitiveNames: Set<String> = ["password", "token", "secret", "body", "message", "recipient", "email", "phone"]

        return arguments.mapValuesWithKeys { key, value in
            if sensitiveNames.contains(key) || implicitSensitiveNames.contains(key.lowercased()) {
                return .string("<redacted>")
            }
            return value
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    func mapValuesWithKeys(_ transform: (String, JSONValue) -> JSONValue) -> [String: JSONValue] {
        var result: [String: JSONValue] = [:]
        for (key, value) in self {
            result[key] = transform(key, value)
        }
        return result
    }
}
