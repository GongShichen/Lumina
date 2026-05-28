import AppIntents
import LuminaAgentRuntime
import Foundation

enum LuminaDestination: String, AppEnum {
    case today
    case memory
    case settings
    case trust

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Lumina Destination")

    static let caseDisplayRepresentations: [LuminaDestination: DisplayRepresentation] = [
        .today: DisplayRepresentation(title: "Today", image: .init(systemName: "sun.max.fill")),
        .memory: DisplayRepresentation(title: "Memory", image: .init(systemName: "brain.head.profile")),
        .settings: DisplayRepresentation(title: "Settings", image: .init(systemName: "gearshape.fill")),
        .trust: DisplayRepresentation(title: "Trust", image: .init(systemName: "lock.shield.fill"))
    ]
}
