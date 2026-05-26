import Foundation

public enum LuminaReActSchema {
    public static let thoughtExample = #"{"type":"thought","thought":"brief status"}"#
    public static let toolUseExample = #"{"type":"tool_use","thought":"why this tool","tool_name":"exact tool name","parameters":{},"requires_confirmation":false}"#
    public static let finalAnswerExample = #"{"type":"final_answer","thought":"done","content":"concise markdown answer"}"#

    public static let promptContract = """
    Output exactly one JSON object and no prose outside JSON.
    ReAct step schema:
    Thought: \(thoughtExample)
    Tool use: \(toolUseExample)
    Final: \(finalAnswerExample)

    Schema rules:
    - type must be one of thought, tool_use, final_answer.
    - For tools, type must be the literal string "tool_use"; never put a tool name in type.
    - tool_use uses top-level tool_name and parameters.
    - tool_name contains the exact tool name. parameters contains the JSON object passed to the tool.
    - parameters must be a JSON object; use {} when there are no inputs.
    - requires_confirmation is optional; set true for side-effect tools.
    - The runtime creates observations after tools run. The model must never output type=observation.
    - Do not use nested tool_use, tool_call, action, tool_code, arguments, input, targetReference, or put the tool name in type.
    - Do not use markdown fences, XML tags, Action:, or Observation:.
    - Invalid: {"type":"device.current_time","input":{}}
    - Valid: {"type":"tool_use","tool_name":"device.current_time","parameters":{}}
    """

    public static let compactPromptContract = """
    CRITICAL OUTPUT CONTRACT: Return one JSON object only. No prose.
    The only valid ReAct JSON shapes are:
    {"type":"tool_use","thought":"...","tool_name":"tool.name","parameters":{},"requires_confirmation":false}
    {"type":"final_answer","thought":"...","content":"markdown"}
    type is only "tool_use" or "final_answer".
    For tools, use exactly these top-level keys: type, thought, tool_name, parameters, requires_confirmation.
    Forbidden keys/values: tool_call, function, args, arguments, input, targetReference, action, toolUse, name.
    If you want a tool, type must be "tool_use"; the exact tool goes in tool_name; inputs go in parameters.
    Use only tool_name from Tools(all). Never output observation; observations are runtime-only. No markdown fences.
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
        Do not preserve invalid field names. Do not explain.

        Parser error:
        \(parserError)

        Invalid JSON:
        \(invalidJSON)

        \(promptContract)

        If the previous response used type=observation, convert its useful content into final_answer.content or choose a valid tool_use.
        If the previous response used {"type":"some.tool","input":...}, convert it to {"type":"tool_use","tool_name":"some.tool","parameters":...}.
        If the previous response used targetReference, move that value to tool_name.
        If the previous response used input or arguments, move that object to parameters.
        If the previous response used args, move that object to parameters.
        If the previous response used function like "device.current_time()", remove "()" and put "device.current_time" in tool_name.
        If the previous response used type=tool_call, change type to tool_use.
        Never output keys named function, args, arguments, input, targetReference, action, tool_call, or name.

        Required shapes:
        - Tool: {"type":"tool_use","thought":"short reason","tool_name":"EXACT_TOOL_NAME","parameters":{},"requires_confirmation":false}
        - Final: {"type":"final_answer","thought":"done","content":"markdown answer"}

        Use only these tool names: \(availableToolNames.sorted().joined(separator: ", ")).

        Original prompt:
        \(originalPrompt)
        """
    }
}
