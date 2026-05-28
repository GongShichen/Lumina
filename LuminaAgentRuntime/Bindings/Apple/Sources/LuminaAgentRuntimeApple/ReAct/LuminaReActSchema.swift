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
        originalPrompt: String,
        task: String = "",
        lastObservation: String = "",
        focusedToolSchemas: String = ""
    ) -> String {
        """
        Repair the previous model response into exactly one valid Lumina ReAct JSON object.
        Output JSON only. No prose, no markdown fence, no XML tags, no Thought:/Action: labels.

        User task:
        \(task.isEmpty ? originalPrompt : task)

        Latest runtime observation, if any:
        \(lastObservation.isEmpty ? "none" : lastObservation)

        Parser/validator error:
        \(parserError)

        Previous invalid response:
        \(invalidJSON)

        Valid output shapes:
        {"type":"tool_use","thought":"short reason","tool_name":"EXACT_TOOL_NAME","parameters":{},"requires_confirmation":false}
        {"type":"final_answer","thought":"done","content":"concise markdown answer"}
        {"type":"cannot_complete","thought":"blocked","reason":"short recoverable reason"}

        Repair rules:
        - If a tool is still needed, use type="tool_use"; put the exact tool name in tool_name; put only tool parameters in parameters.
        - If the latest runtime observation already satisfies the user task, use final_answer.content as user-facing Markdown.
        - Never output observation; observations are runtime-owned.
        - Never repeat an identical tool call that the latest observation says already succeeded or was replayed.
        - Never output keys named tool_call, tool_use, function, args, arguments, input, targetReference, action, name, duration, or command.
        - If the invalid response said "Call some.tool" or contained a tool_use field, convert that intention to the valid tool_use shape.
        - If the invalid response used a date from the past, recompute from the latest device.current_time observation when possible.

        Use only these tool names: \(availableToolNames.sorted().joined(separator: ", ")).

        Focused tool schema summary:
        \(focusedToolSchemas.isEmpty ? "none" : focusedToolSchemas)
        """
    }
}
