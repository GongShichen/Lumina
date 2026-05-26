import Foundation

public actor LuminaInMemoryAuditLogger: LuminaAuditLogger {
    private var records: [LuminaAuditRecord] = []

    public init() {}

    public func append(_ record: LuminaAuditRecord) {
        records.append(record)
    }

    public func allRecords() -> [LuminaAuditRecord] {
        records
    }
}
