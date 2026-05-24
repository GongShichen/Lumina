import Foundation

struct LuminaAgentActivitySnapshot: Equatable, Sendable {
    var state: LuminaAgentActivityState
    var title: String
    var detail: String
    var toolName: String?
    var progress: Double
    var isLocalOnly: Bool

    static let idle = LuminaAgentActivitySnapshot(
        state: .idle,
        title: "准备就绪",
        detail: "所有动作都会在执行前确认。",
        toolName: nil,
        progress: 0,
        isLocalOnly: true
    )
}
