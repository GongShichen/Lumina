import Foundation

struct LuminaBenchmarkSnapshot: Equatable {
    enum State: Equatable {
        case idle
        case running
        case finished
        case failed(String)
        case cancelled
    }

    var state: State = .idle
    var currentTask: String = ""
    var completed: Int = 0
    var total: Int = 200
    var latestTool: String?
    var report: LuminaBenchmarkReport?

    var progress: Double {
        total == 0 ? 0 : min(1, Double(completed) / Double(total))
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }
}
