import Foundation

public enum BuiltInToolFactory {
    public static func echoSearchTool() -> AnyAgentTool {
        AnyAgentTool(
            schema: ToolSchema(
                name: "local.search",
                description: "Search local personal memory and return compact cited snippets.",
                parameters: [
                    ToolParameterSchema(name: "query", type: .string, description: "Search query."),
                    ToolParameterSchema(name: "limit", type: .number, description: "Maximum result count.", required: false)
                ],
                sideEffect: .readOnly,
                sensitivity: .privateData
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            let query = arguments.string("query") ?? ""
            return ToolResult(
                callID: UUID(),
                toolName: "local.search",
                status: .succeeded,
                output: ["summary": .string("No memory store attached. Query was: \(query)")]
            )
        }
    }
}
