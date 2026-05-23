import Foundation

public protocol Planner: Sendable {
    func makePlan(for request: AgentRequest, availableTools: [ToolSchema]) async throws -> AgentPlan
}

public struct FoundationModelsPlanner: Planner {
    private let fallback: RuleBasedPlanner

    public init(fallback: RuleBasedPlanner = RuleBasedPlanner()) {
        self.fallback = fallback
    }

    public func makePlan(for request: AgentRequest, availableTools: [ToolSchema]) async throws -> AgentPlan {
        // The concrete FoundationModels session is intentionally isolated behind this type.
        // The fallback keeps the framework testable on simulators, macOS CI, and unsupported devices.
        try Task.checkCancellation()
        return try await fallback.makePlan(for: request, availableTools: availableTools)
    }
}

public typealias Gemma4CoreMLPlanner = ModelBackedPlanner

public struct RuleBasedPlanner: Planner {
    public init() {}

    public func makePlan(for request: AgentRequest, availableTools: [ToolSchema]) async throws -> AgentPlan {
        try Task.checkCancellation()
        let text = request.text.lowercased()
        var calls: [ToolCall] = []

        func hasTool(_ name: String) -> Bool {
            availableTools.contains { $0.name == name }
        }

        if hasTool("local.search") && (text.contains("查") || text.contains("找") || text.contains("search") || text.contains("会议")) {
            calls.append(ToolCall(
                toolName: "local.search",
                arguments: ["query": .string(request.text), "limit": .number(5)]
            ))
        }

        if hasTool("calendar.search") && (text.contains("calendar") || text.contains("日历") || text.contains("会议") || text.contains("meeting")) {
            calls.append(ToolCall(
                toolName: "calendar.search",
                arguments: ["query": .string(request.text), "limit": .number(5)]
            ))
        }

        if hasTool("reminder.create") && (text.contains("提醒") || text.contains("remind")) {
            calls.append(ToolCall(
                toolName: "reminder.create",
                arguments: ["title": .string(request.text)],
                requiresConfirmation: true
            ))
        }

        if hasTool("message.compose") && (text.contains("短信") || text.contains("消息") || text.contains("message") || text.contains("发给")) {
            calls.append(ToolCall(
                toolName: "message.compose",
                arguments: ["body": .string(request.text)],
                requiresConfirmation: true
            ))
        }

        if hasTool("ledger.record") && (text.contains("记账") || text.contains("支出") || text.contains("expense") || text.contains("花了")) {
            calls.append(ToolCall(
                toolName: "ledger.record",
                arguments: ["memo": .string(request.text)],
                requiresConfirmation: true
            ))
        }

        if hasTool("subscription.add") && (text.contains("订阅") || text.contains("subscribe") || text.contains("rss")) {
            calls.append(ToolCall(
                toolName: "subscription.add",
                arguments: ["source": .string(request.text)],
                requiresConfirmation: true
            ))
        }

        if hasTool("media.import") && request.content.contains(where: { $0.modality != .text && $0.modality != .structuredData }) {
            calls.append(ToolCall(
                toolName: "media.import",
                arguments: ["note": .string(request.text)],
                requiresConfirmation: true
            ))
        }

        if calls.isEmpty, hasTool("local.search") {
            calls.append(ToolCall(
                toolName: "local.search",
                arguments: ["query": .string(request.text), "limit": .number(5)]
            ))
        }

        return AgentPlan(summary: "Generated \(calls.count) tool call(s) for the request.", toolCalls: calls)
    }
}
