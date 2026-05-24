import AgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

extension LuminaAgentTool {
    func eraseToAnyTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(self)
    }
}
