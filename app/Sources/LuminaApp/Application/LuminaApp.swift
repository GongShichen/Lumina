import LuminaAgentRuntime
import PersonalMemory
import SwiftUI

@main
struct LuminaApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if LuminaToolCallingRegression.isEnabled {
                Text("Lumina 工具调用回归测试中…")
                    .frame(minWidth: 480, minHeight: 240)
                    .task {
                        await LuminaToolCallingRegression.runAndExit()
                    }
            } else {
                ApplicationContent()
            }
            #else
            ApplicationContent()
            #endif
        }
    }

    private struct ApplicationContent: View {
        @StateObject private var services = AgentAppServices()

        var body: some View {
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
