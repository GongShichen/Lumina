import Foundation

public protocol LuminaAuditLogReader: Sendable {
    func recentRecords(limit: Int) async -> [LuminaAuditRecord]
}
