import AgentRuntime
import PersonalMemory
import SwiftUI

@main
struct LuminaApp: App {
    @StateObject private var services = AgentAppServices()

    var body: some Scene {
        WindowGroup {
            ZStack {
                LuminaAppBackground()
                AgentHomeView(services: services)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(LuminaTheme.paper)
            .ignoresSafeArea()
        }
    }
}
