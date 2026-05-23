import AppIntents
import AgentRuntime
import Foundation

struct RunAgentIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Local Agent"
    static let description = IntentDescription("Run a local-first agent request through the app tool runtime.")
    static let openAppWhenRun = true

    @Parameter(title: "Request")
    var request: String

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let services = AgentAppServices(environment: .live())
        let result = await services.run(request)
        return .result(dialog: IntentDialog("Agent finished with status \(result.status.rawValue)."))
    }
}
