import Foundation

enum LuminaEmbeddingScheduler {
    static var backgroundPriority: TaskPriority {
        ProcessInfo.processInfo.isLowPowerModeEnabled ? .background : .utility
    }
}
