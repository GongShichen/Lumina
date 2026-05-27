import AppIntents
import LuminaAgentRuntime
import Foundation

struct LuminaShortcutsProvider: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenLuminaIntent(),
            phrases: [
                "Open \(.applicationName)",
                "Show my \(.applicationName) memory"
            ],
            shortTitle: "Open Lumina",
            systemImageName: "sparkles"
        )

        AppShortcut(
            intent: RunAgentIntent(),
            phrases: [
                "Ask \(.applicationName)",
                "Run a local request in \(.applicationName)"
            ],
            shortTitle: "Ask Lumina",
            systemImageName: "text.bubble.fill"
        )
    }
}
