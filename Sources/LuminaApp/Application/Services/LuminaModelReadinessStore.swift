import Combine
import Foundation

@MainActor
final class LuminaModelReadinessStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot = LuminaModelReadinessSnapshot.initial

    func markPlannerFallback(_ message: String) {
        snapshot.plannerState = .fallbackUsed
        snapshot.plannerSource = "Planner unavailable"
        snapshot.plannerMessage = message
        snapshot.lastRunUsedFallback = true
    }

    func markPlannerReady(source: String, message: String) {
        snapshot.plannerState = .ready
        snapshot.plannerSource = source
        snapshot.plannerMessage = message
    }

    func markPlannerUnavailable(_ message: String) {
        snapshot.plannerState = .unavailable
        snapshot.plannerSource = "No local planner model"
        snapshot.plannerMessage = message
    }

    func markPlannerFailed(_ message: String) {
        snapshot.plannerState = .failed
        snapshot.plannerSource = "Local planner model failed"
        snapshot.plannerMessage = message
    }

    func markPlannerModelRun(source: String) {
        snapshot.plannerState = .ready
        snapshot.plannerSource = source
        snapshot.plannerMessage = "本次由端侧模型 planner 生成结构化 action/final。"
        snapshot.lastRunUsedFallback = false
    }

    func markEmbeddingReady(source: String, message: String) {
        snapshot.embeddingState = .ready
        snapshot.embeddingSource = source
        snapshot.embeddingMessage = message
    }

    func markEmbeddingUnavailable(_ message: String) {
        snapshot.embeddingState = .unavailable
        snapshot.embeddingSource = "Hashing fallback"
        snapshot.embeddingMessage = message
    }
}
