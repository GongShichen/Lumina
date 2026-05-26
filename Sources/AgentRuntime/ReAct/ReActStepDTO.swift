import Foundation

struct ReActStepDTO: Decodable {
    var type: String
    var thought: String?
    var toolName: String?
    var parameters: [String: LuminaJSONValue]?
    var requiresConfirmation: Bool?
    var content: String?

    enum CodingKeys: String, CodingKey {
        case type
        case thought
        case toolName = "tool_name"
        case parameters
        case requiresConfirmation = "requires_confirmation"
        case content
    }
}
