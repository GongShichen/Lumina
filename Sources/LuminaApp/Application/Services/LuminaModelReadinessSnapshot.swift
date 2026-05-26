import Foundation

struct LuminaModelReadinessSnapshot: Equatable, Sendable {
    var modelState: LuminaModelReadinessState
    var embeddingState: LuminaModelReadinessState
    var modelSource: String
    var embeddingSource: String
    var modelMessage: String
    var embeddingMessage: String
    var lastRunUsedFallback: Bool

    static let initial = LuminaModelReadinessSnapshot(
        modelState: .loading,
        embeddingState: .loading,
        modelSource: "Preparing",
        embeddingSource: "Preparing",
        modelMessage: "端侧模型正在后台准备。",
        embeddingMessage: "端侧 embedding 会在首次检索时懒加载。",
        lastRunUsedFallback: false
    )
}
