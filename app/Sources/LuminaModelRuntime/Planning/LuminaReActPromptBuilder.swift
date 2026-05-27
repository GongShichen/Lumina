import LuminaAgentRuntime
import Foundation

public typealias LuminaReActPromptBuilder = @Sendable (LuminaReActStepContext) async throws -> String
