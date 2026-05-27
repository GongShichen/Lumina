import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaCalendarEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var startDate: Date
    public var endDate: Date?
    public var notes: String?

    public init(id: UUID = UUID(), title: String, startDate: Date = Date(), endDate: Date? = nil, notes: String? = nil) {
        self.id = id
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.notes = notes
    }
}
