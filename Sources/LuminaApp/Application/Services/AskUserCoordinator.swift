import Foundation
import LuminaAppCore

@MainActor
final class AskUserCoordinator: ObservableObject {
    @Published var pending: LuminaAskUserRequest?
    @Published var lastStatus: AskUserStatus?

    private var continuations: [UUID: CheckedContinuation<LuminaAskUserResponse, Never>] = [:]

    nonisolated func ask(_ request: LuminaAskUserRequest) async -> LuminaAskUserResponse {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                continuations[request.id] = continuation
                pending = request
                lastStatus = AskUserStatus(
                    title: "等待你的选择",
                    detail: request.reason,
                    isWaiting: true
                )
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
        pending = nil
        lastStatus = AskUserStatus(
            title: response.cancelled ? "已暂停执行" : "已收到回答",
            detail: response.cancelled ? "Lumina 不会继续执行后续动作" : "继续执行本地 agent loop",
            isWaiting: false
        )
        continuations.removeValue(forKey: response.requestID)?.resume(returning: response)
    }
}
