import LuminaAgentClient
import Foundation

struct LuminaObservedRunTimings: Codable, Hashable {
    var wallClockMilliseconds: Double
    var activeRuntimeMilliseconds: Double
    var confirmationWaitMilliseconds: Double
    var systemPermissionWaitMilliseconds: Double
    var observedToolExecutionMilliseconds: Double

    static let empty = LuminaObservedRunTimings(
        wallClockMilliseconds: 0,
        activeRuntimeMilliseconds: 0,
        confirmationWaitMilliseconds: 0,
        systemPermissionWaitMilliseconds: 0,
        observedToolExecutionMilliseconds: 0
    )
}
