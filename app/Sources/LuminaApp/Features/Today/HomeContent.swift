import Foundation

struct HomeContent: Hashable, Sendable {
    var greetingTitle: String
    var greetingSubtitle: String
    var defaultPrompt: String
    var suggestions: [HomeSuggestion]

    static func loading() -> HomeContent {
        HomeContent(
            greetingTitle: "Lumina 正在整理本机上下文",
            greetingSubtitle: "我会只读取必要摘要，并在执行敏感动作前确认。",
            defaultPrompt: "",
            suggestions: []
        )
    }
}
