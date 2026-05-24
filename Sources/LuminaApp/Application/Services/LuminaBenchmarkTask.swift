import Foundation

struct LuminaBenchmarkTask: Identifiable, Codable, Hashable {
    let id: String
    let text: String
    let expectedTools: [String]
    let category: String
    let sideEffect: Bool
    let cleanupPrefixes: [String]
}
