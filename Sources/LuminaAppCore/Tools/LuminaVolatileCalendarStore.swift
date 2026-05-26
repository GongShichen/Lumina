import LuminaAgentClient
import Foundation
import PersonalMemory

public actor LuminaVolatileCalendarStore {
    private var events: [LuminaCalendarEvent]
    private var reminders: [LuminaReminderItem] = []

    public init(events: [LuminaCalendarEvent] = []) {
        self.events = events
    }

    public func searchEvents(query: String, limit: Int) -> [LuminaCalendarEvent] {
        let lowered = query.lowercased()
        return events
            .filter { lowered.isEmpty || $0.title.lowercased().contains(lowered) || lowered.contains("会议") }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    public func addReminder(_ reminder: LuminaReminderItem) -> String {
        reminders.append(reminder)
        return reminder.id.uuidString
    }

    public func addEvent(_ event: LuminaCalendarEvent) -> String {
        events.append(event)
        return event.id.uuidString
    }

    public func removeEvent(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = events.count
        events.removeAll { $0.id == uuid }
        return events.count < before
    }

    public func updateEvent(
        id: String,
        title: String?,
        startDate: Date?,
        endDate: Date?,
        notes: String?
    ) -> LuminaCalendarEvent? {
        guard let uuid = UUID(uuidString: id),
              let index = events.firstIndex(where: { $0.id == uuid }) else {
            return nil
        }
        var event = events[index]
        if let title, !title.isEmpty {
            event.title = title
        }
        if let startDate {
            event.startDate = startDate
        }
        if let endDate {
            event.endDate = endDate
        }
        if let notes {
            event.notes = notes
        }
        events[index] = event
        return event
    }

    public func removeReminder(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = reminders.count
        reminders.removeAll { $0.id == uuid }
        return reminders.count < before
    }

    public func updateReminder(
        id: String,
        title: String?,
        notes: String?,
        dueDate: Date?,
        isCompleted: Bool?
    ) -> LuminaReminderItem? {
        guard let uuid = UUID(uuidString: id),
              let index = reminders.firstIndex(where: { $0.id == uuid }) else {
            return nil
        }
        var reminder = reminders[index]
        if let title, !title.isEmpty {
            reminder.title = title
        }
        if let notes {
            reminder.notes = notes
        }
        if let dueDate {
            reminder.dueDate = dueDate
        }
        if let isCompleted {
            reminder.isCompleted = isCompleted
        }
        reminders[index] = reminder
        return reminder
    }

    public func allReminders() -> [LuminaReminderItem] {
        reminders
    }

    public func allEvents() -> [LuminaCalendarEvent] {
        events
    }
}
