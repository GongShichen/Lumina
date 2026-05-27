import LuminaAgentRuntime
import Foundation

public struct LuminaAppMemoryPermissionGate: LuminaPermissionGate {
    private let fallback = LuminaDefaultPermissionGate()

    public init() {}

    public func decision(for call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaPermissionDecision {
        guard call.toolName == "memory.ingest_text" else {
            return await fallback.decision(for: call, schema: schema, request: request)
        }

        let sensitivity = effectiveSensitivity(for: call)
        switch sensitivity {
        case .low, .normal:
            return .allowed
        case .sensitive, .privateData:
            return .requiresConfirmation(reason: "Lumina 想保存一条较敏感的长期记忆，请确认后再写入本地记忆库。")
        }
    }

    private func effectiveSensitivity(for call: LuminaToolCall) -> LuminaToolSensitivity {
        let requested = LuminaToolSensitivity(rawValue: call.arguments.string("sensitivity") ?? "") ?? .normal
        let sensitiveHints = ["contact", "health", "location", "communication", "message", "email", "clipboard", "document"]
        let source = call.arguments.string("source")?.lowercased() ?? ""
        guard sensitiveHints.contains(where: { source.contains($0) }) else {
            return requested
        }
        switch requested {
        case .low, .normal:
            return .sensitive
        case .sensitive, .privateData:
            return requested
        }
    }
}
