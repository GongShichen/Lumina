import Foundation
import LuminaAppCore

@MainActor
final class AskUserCoordinator: ObservableObject {
    @Published var pending: LuminaAskUserRequest?
    @Published var lastStatus: AskUserStatus?

    private var continuations: [UUID: CheckedContinuation<LuminaAskUserResponse, Never>] = [:]

    nonisolated func ask(_ request: LuminaAskUserRequest) async -> LuminaAskUserResponse {
        await waitForAnswer(request)
    }

    private func waitForAnswer(_ request: LuminaAskUserRequest) async -> LuminaAskUserResponse {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: LuminaAskUserResponse(requestID: request.id, answers: [], cancelled: true))
                    return
                }
                if let pending { cancel(requestID: pending.id) }
                continuations[request.id] = continuation
                pending = request
                lastStatus = AskUserStatus(
                    title: "等待你的选择",
                    detail: request.reason,
                    isWaiting: true
                )
            }
        } onCancel: {
            Task { @MainActor in
                self.cancel(requestID: request.id)
            }
        }
    }

    func submit(requestID: UUID, answers: [LuminaAskUserAnswer]) {
        resolve(LuminaAskUserResponse(requestID: requestID, answers: answers, cancelled: false))
    }

    func cancel(requestID: UUID) {
        resolve(LuminaAskUserResponse(requestID: requestID, answers: [], cancelled: true))
    }

    func resetForNewSession() {
        pending = nil
        lastStatus = nil
        for (id, continuation) in continuations {
            continuation.resume(returning: LuminaAskUserResponse(requestID: id, answers: [], cancelled: true))
        }
        continuations.removeAll()
    }

    private func resolve(_ response: LuminaAskUserResponse) {
        guard let continuation = continuations.removeValue(forKey: response.requestID) else { return }
        if pending?.id == response.requestID { pending = nil }
        lastStatus = AskUserStatus(
            title: response.cancelled ? "已暂停执行" : "已收到回答",
            detail: response.cancelled ? "Lumina 不会继续执行后续动作" : "继续执行本地 agent loop",
            isWaiting: false
        )
        continuation.resume(returning: response)
    }
}
