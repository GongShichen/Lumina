import Foundation

struct LuminaAgenticRLOutcome: Codable, Hashable {
    let status: String
    let reward: Double
    let toolPrecision: Double
    let toolRecall: Double
    let toolF1: Double
    let activeRuntimeMilliseconds: Double
    let wallClockMilliseconds: Double
    let confirmationWaitMilliseconds: Double
    let systemPermissionWaitMilliseconds: Double
    let totalMilliseconds: Double
    let planningMilliseconds: Double
    let toolMilliseconds: Double
    let failureSummary: String?
}
