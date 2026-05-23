import AgentRuntime
import PersonalMemory
import SwiftUI

@main
struct LuminaApp: App {
    @StateObject private var services = AgentAppServices()

    var body: some Scene {
        WindowGroup {
            AgentHomeView()
                .environmentObject(services)
        }
    }
}
