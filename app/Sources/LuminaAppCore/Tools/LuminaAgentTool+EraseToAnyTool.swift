import LuminaAgentRuntime
import Foundation
import PersonalMemory

extension LuminaAgentTool {
    func eraseToAnyTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(self)
    }
}
