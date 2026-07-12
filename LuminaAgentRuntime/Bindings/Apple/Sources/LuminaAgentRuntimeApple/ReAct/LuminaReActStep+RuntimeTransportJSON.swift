import Foundation

extension LuminaReActStep {
    var runtimeTransportJSON: String {
        switch kind {
        case .thought:
            return #"{"type":"reasoning","thinking":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? ""))","requires_followup":true}"#
        case .action:
            guard let action else {
                return #"{"type":"cannot_complete","reason":"action step missing tool call"}"#
            }
            let parameters = (try? String(data: JSONEncoder().encode(action.arguments), encoding: .utf8)) ?? "{}"
            return #"{"type":"tool_use","thinking":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? ""))","tool_name":"\#(LuminaAgentRuntimeAdapterBox.escape(action.toolName))","parameters":\#(parameters),"requires_confirmation":\#(action.requiresConfirmation)}"#
        case .multiAction:
            let calls = toolCalls.map { call -> String in
                let parameters = (try? String(data: JSONEncoder().encode(call.arguments), encoding: .utf8)) ?? "{}"
                return #"{"tool_name":"\#(LuminaAgentRuntimeAdapterBox.escape(call.toolName))","parameters":\#(parameters),"requires_confirmation":\#(call.requiresConfirmation)}"#
            }.joined(separator: ",")
            return #"{"type":"multi_tool_use","thinking":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? ""))","tool_calls":[\#(calls)]}"#
        case .observation:
            return #"{"type":"reasoning","thinking":"observation received","requires_followup":true}"#
        case .result:
            return #"{"type":"result","thinking":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? "done"))","content":"\#(LuminaAgentRuntimeAdapterBox.escape(resultMarkdown ?? ""))","completed":true}"#
        }
    }
}
