import Foundation

public protocol LuminaAuditLogger: Sendable {
    func append(_ record: LuminaAuditRecord) async
}
