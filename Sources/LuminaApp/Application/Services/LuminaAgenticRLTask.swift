import Foundation

struct LuminaAgenticRLTask: Identifiable, Codable, Hashable {
    let id: String
    let instruction: String
    let category: String
    let expectedTools: [String]
    let difficulty: String
    let cleanupPrefixes: [String]
}
