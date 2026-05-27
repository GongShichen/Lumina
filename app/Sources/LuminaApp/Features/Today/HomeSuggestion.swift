import Foundation

struct HomeSuggestion: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var prompt: String
    var icon: String
}
