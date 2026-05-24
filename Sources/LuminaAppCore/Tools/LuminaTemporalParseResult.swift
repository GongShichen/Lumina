import Foundation

public struct LuminaTemporalParseResult: Codable, Hashable, Sendable {
    public var title: String
    public var startDate: Date
    public var endDate: Date?

    public init(title: String, startDate: Date, endDate: Date? = nil) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }
}
