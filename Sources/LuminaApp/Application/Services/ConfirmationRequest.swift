import AgentRuntime
import Foundation

struct ConfirmationRequest: Identifiable {
    let id: UUID
    let call: LuminaToolCall
    let schema: LuminaToolSchema
    let reason: String
}
