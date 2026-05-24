import AgentRuntime
import Foundation

public typealias LuminaReActPromptBuilder = @Sendable (LuminaReActPlannerContext) async throws -> String
