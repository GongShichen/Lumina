import Foundation

extension LuminaReActStep {
    var runtimeTransportJSON: String {
        switch kind {
        case .thought:
            return #"{"type":"reasoning","thought":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? ""))","requires_followup":true}"#
        case .action:
            guard let action else {
                return #"{"type":"cannot_complete","reason":"action step missing tool call"}"#
            }
            let parameters = (try? String(data: JSONEncoder().encode(action.arguments), encoding: .utf8)) ?? "{}"
            return #"{"type":"tool_use","thought":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? ""))","tool_name":"\#(LuminaAgentRuntimeAdapterBox.escape(action.toolName))","parameters":\#(parameters),"requires_confirmation":\#(action.requiresConfirmation)}"#
        case .observation:
            return #"{"type":"reasoning","thought":"observation received","requires_followup":true}"#
        case .final:
            return #"{"type":"final_answer","thought":"\#(LuminaAgentRuntimeAdapterBox.escape(thought ?? "done"))","content":"\#(LuminaAgentRuntimeAdapterBox.escape(finalMarkdown ?? ""))","completed":true}"#
        }
    }
}
