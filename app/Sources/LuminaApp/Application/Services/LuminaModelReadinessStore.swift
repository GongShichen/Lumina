import Combine
import Foundation

@MainActor
final class LuminaModelReadinessStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var snapshot = LuminaModelReadinessSnapshot.initial

    func markModelFallback(_ message: String) {
        snapshot.modelState = .fallbackUsed
        snapshot.modelSource = "Model unavailable"
        snapshot.modelMessage = message
        snapshot.lastRunUsedFallback = true
    }

    func markModelReady(source: String, message: String) {
        snapshot.modelState = .ready
        snapshot.modelSource = source
        snapshot.modelMessage = message
    }

    func markModelUnavailable(_ message: String) {
        snapshot.modelState = .unavailable
        snapshot.modelSource = "No local model"
        snapshot.modelMessage = message
    }

    func markModelFailed(_ message: String) {
        snapshot.modelState = .failed
        snapshot.modelSource = "Local model failed"
        snapshot.modelMessage = message
    }

    func markModelRun(source: String) {
        snapshot.modelState = .ready
        snapshot.modelSource = source
        snapshot.modelMessage = "本次由端侧模型生成标准 ReAct action/final。"
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
