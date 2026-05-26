import Foundation

extension LuminaReActStep {
    var runtimeTransportJSON: String {
        switch kind {
        case .thought:
            return #"{"type":"reasoning","thought":"\#(LuminaAgentRuntimeClientBox.escape(thought ?? ""))","requires_followup":true}"#
        case .action:
            guard let action else {
                return #"{"type":"cannot_complete","reason":"action step missing tool call"}"#
            }
            let parameters = (try? String(data: JSONEncoder().encode(action.arguments), encoding: .utf8)) ?? "{}"
            return #"{"type":"tool_use","thought":"\#(LuminaAgentRuntimeClientBox.escape(thought ?? ""))","tool_name":"\#(LuminaAgentRuntimeClientBox.escape(action.toolName))","parameters":\#(parameters),"requires_confirmation":\#(action.requiresConfirmation)}"#
        case .observation:
            return #"{"type":"reasoning","thought":"observation received","requires_followup":true}"#
        case .final:
            return #"{"type":"final_answer","thought":"\#(LuminaAgentRuntimeClientBox.escape(thought ?? "done"))","content":"\#(LuminaAgentRuntimeClientBox.escape(finalMarkdown ?? ""))","completed":true}"#
        }
    }
}
