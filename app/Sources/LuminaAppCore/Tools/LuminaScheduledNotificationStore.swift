import Foundation

public actor LuminaScheduledNotificationStore {
    private var notifications: [LuminaScheduledNotification] = []

    public init() {}

    public func append(_ notification: LuminaScheduledNotification) {
        notifications.append(notification)
    }

    public func all() -> [LuminaScheduledNotification] {
        notifications
    }
}
