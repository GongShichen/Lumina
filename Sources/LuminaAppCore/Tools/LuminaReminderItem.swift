import AgentRuntime
import Foundation
import PersonalMemory

public struct LuminaReminderItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String?
    public var dueDate: Date?
    public var isCompleted: Bool

    public init(id: UUID = UUID(), title: String, notes: String? = nil, dueDate: Date? = nil, isCompleted: Bool = false) {
        self.id = id
        self.title = title
        self.notes = notes
        self.dueDate = dueDate
        self.isCompleted = isCompleted
    }
}
