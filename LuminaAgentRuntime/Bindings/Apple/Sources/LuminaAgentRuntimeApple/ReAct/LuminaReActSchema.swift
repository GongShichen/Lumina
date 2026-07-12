import Foundation

public enum LuminaReActSchema {
    public static let toolUseExample = """
    <tool_call>
    <function=EXACT_TOOL_NAME>
    <parameter=parameter_name>
    value
    </parameter>
    </function>
    </tool_call>
    """
    public static let resultExample = "When no more tool work is needed, answer normally in concise Markdown."

    public static let promptContract = """
    TOOL USE CONTRACT

    Rules:
    - Valid outputs are either a concise final answer or one MiniCPM-V4.6 tool call.
    - Optional private reasoning belongs inside <think>...</think>.
    - Select the exact visible tool name. Put each input field in one <parameter=field_name>...</parameter> block.
    - For tools with no inputs, emit the <function=tool.name> block with no parameter blocks.
    - A tool call response ends at </tool_call>.
    - Answer normally only when the whole user goal is complete from runtime observations.
    - Runtime owns observations, permissions, and confirmations.
    """

    public static let compactPromptContract = """
    Use MiniCPM-V4.6 chat-template tool calls for tools; otherwise answer normally.
    Tool-call shape:
    <tool_call>
    <function=EXACT_TOOL_NAME>
    <parameter=field_name>
    value
    </parameter>
    </function>
    </tool_call>
    Use only tool names from Tools(all). Match parameter names exactly; omit parameter blocks only when input is {}.
    Optional private reasoning belongs inside <think>...</think>. Runtime owns observations, permissions, and confirmations.
    """
}
