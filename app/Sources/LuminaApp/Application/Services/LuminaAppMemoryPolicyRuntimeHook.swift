import LuminaAgentRuntime
import LuminaAppCore
import Foundation

struct LuminaAppMemoryPolicyRuntimeHook: LuminaAgentRuntimeHook {
    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        guard event == .stepContextReady,
              context.availableTools.contains(where: { $0.name == "memory.ingest_text" })
        else {
            return []
        }

        return [
            .appendContextSection(LuminaRuntimeContextSection(
                id: "app.memory_policy.agentic_persistence",
                title: "Persistent memory policy",
                summary: "Agent may save durable user memory only when it is useful beyond this task.",
                content: """
                You may call memory.ingest_text only when a fact, preference, durable plan, or user instruction is likely to be useful in future sessions. Transient tool observations, temporary reasoning, one-off task progress, raw sensitive content, and unstated user preferences are outside durable memory unless clearly reusable. Include reason, memoryType, retentionHint, source, and sensitivity in parameters. Use sensitive or privateData for contact, health, location, communication, clipboard, or document-body content.
                """,
                source: "app/policy",
                sensitivity: .normal,
                disclosureLevel: 0
            )),
            .annotate(key: "app.memoryPolicy", value: .string("agentic_persistence_available"))
        ]
    }
}

struct LuminaToolRecoveryRuntimeHook: LuminaMatchingAgentRuntimeHook {
    let matcher = LuminaAgentRuntimeHookMatcher(events: [.beforeTool, .stepContextReady])

    func handle(
        event: LuminaAgentRuntimeHookEvent,
        context: LuminaAgentRuntimeHookContext
    ) async throws -> [LuminaAgentRuntimeHookDirective] {
        try await LuminaToolRecoveryRuntimePolicy().handle(event: event, context: context)
    }
}
