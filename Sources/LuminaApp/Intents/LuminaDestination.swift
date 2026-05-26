import AppIntents
import LuminaAgentClient
import Foundation

enum LuminaDestination: String, AppEnum {
    case today
    case memory
    case activity
    case trust

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lumina Destination")

    static let caseDisplayRepresentations: [LuminaDestination: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today", image: .init(systemName: "sun.max.fill")),
        .memory: DisplayRepresentation(title: "Memory", image: .init(systemName: "brain.head.profile")),
        .activity: DisplayRepresentation(title: "Activity", image: .init(systemName: "clock.badge.checkmark")),
        .trust: DisplayRepresentation(title: "Trust", image: .init(systemName: "lock.shield.fill"))
    ]
}
