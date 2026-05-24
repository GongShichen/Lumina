import Foundation

public actor LuminaJSONLAuditLogger: LuminaAuditLogger, LuminaAuditLogReader {
    private let url: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) {
        self.url = url
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public func append(_ record: LuminaAuditRecord) async {
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

    public func recentRecords(limit: Int) async -> [LuminaAuditRecord] {
        guard limit > 0,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(limit)
            .compactMap { line in
                guard let data = String(line).data(using: .utf8) else { return nil }
                return try? decoder.decode(LuminaAuditRecord.self, from: data)
            }
            .reversed()
    }
}
