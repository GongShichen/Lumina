import Foundation

struct LuminaModelReadinessSnapshot: Equatable, Sendable {
    var plannerState: LuminaModelReadinessState
    var embeddingState: LuminaModelReadinessState
    var plannerSource: String
    var embeddingSource: String
    var plannerMessage: String
    var embeddingMessage: String
    var lastRunUsedFallback: Bool

    static let initial = LuminaModelReadinessSnapshot(
        plannerState: .loading,
        embeddingState: .loading,
        plannerSource: "Preparing",
        embeddingSource: "Preparing",
        plannerMessage: "端侧 planner 正在后台准备。",
        embeddingMessage: "端侧 embedding 会在首次检索时懒加载。",
        lastRunUsedFallback: false
    )
}
