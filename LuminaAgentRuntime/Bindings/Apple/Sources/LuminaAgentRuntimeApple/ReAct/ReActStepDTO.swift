import Foundation

struct ReActStepDTO: Decodable {
    var type: String
    var thinking: String?
    var toolName: String?
    var parameters: [String: LuminaJSONValue]?
    var requiresConfirmation: Bool?
    var content: String?
    var toolCalls: [ReActToolCallDTO]?

    enum CodingKeys: String, CodingKey {
        case type
        case thinking
        case toolName = "tool_name"
        case parameters
        case requiresConfirmation = "requires_confirmation"
        case content
        case toolCalls = "tool_calls"
    }
}

struct ReActToolCallDTO: Decodable {
    var toolName: String
    var parameters: [String: LuminaJSONValue]?
    var requiresConfirmation: Bool?

    enum CodingKeys: String, CodingKey {
        case toolName = "tool_name"
        case parameters
        case requiresConfirmation = "requires_confirmation"
    }
}
