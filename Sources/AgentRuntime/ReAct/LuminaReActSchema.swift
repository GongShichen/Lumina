import Foundation

public enum LuminaReActSchema {
    public static let thoughtExample = #"{"type":"thought","thought":"brief status"}"#
    public static let toolUseExample = #"{"type":"tool_use","thought":"why this tool","tool_name":"exact tool name","parameters":{},"requires_confirmation":false}"#
    public static let finalAnswerExample = #"{"type":"final_answer","thought":"done","final_answer":"concise markdown answer"}"#

    public static let promptContract = """
    Output exactly one JSON object and no prose outside JSON.
    ReAct step schema:
    Thought: \(thoughtExample)
    Tool use: \(toolUseExample)
    Final: \(finalAnswerExample)

    Schema rules:
    - type must be one of thought, tool_use, final_answer.
    - tool_use uses top-level tool_name and parameters.
    - parameters must be a JSON object; use {} when there are no inputs.
    - requires_confirmation is optional; set true for side-effect tools.
    - Do not use nested tool_use, tool_call, action, tool_code, arguments, or put the tool name in type.
    - Do not use markdown fences, XML tags, Action:, or Observation:.
    """

    public static func repairPrompt(
        invalidJSON: String,
        parserError: String,
        availableToolNames: [String],
        originalPrompt: String
    ) -> String {
        """
        Your previous response was invalid ReAct JSON and was not executed.
        Rewrite it as exactly one valid standard ReAct JSON object.

        Parser error:
        \(parserError)

        Invalid JSON:
        \(invalidJSON)

        \(promptContract)

        Use only these tool names: \(availableToolNames.sorted().joined(separator: ", ")).

        Original prompt:
        \(originalPrompt)
        """
    }
}
