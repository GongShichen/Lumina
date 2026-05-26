import AppIntents
import LuminaAgentClient
import Foundation

struct OpenLuminaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Lumina"
    static let description = IntentDescription("Open Lumina to a focused local-first personal agent surface.")
    static let openAppWhenRun = true

    @Parameter(title: "Destination", default: .today)
    var destination: LuminaDestination

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog("Opening Lumina \(destination.rawValue)."))
    }
}
