import Foundation

public struct LuminaMemorySearchQuery: Sendable {
    public var text: String
    public var limit: Int
    public var sourceKinds: Set<LuminaMemorySourceKind>?
    public var since: Date?
    public var until: Date?
    public var maximumSensitivity: LuminaMemorySensitivity

    public init(
        text: String,
        limit: Int = 5,
        sourceKinds: Set<LuminaMemorySourceKind>? = nil,
        since: Date? = nil,
        until: Date? = nil,
        maximumSensitivity: LuminaMemorySensitivity = .privateData
    ) {
        self.text = text
        self.limit = limit
        self.sourceKinds = sourceKinds
        self.since = since
        self.until = until
        self.maximumSensitivity = maximumSensitivity
    }
}
