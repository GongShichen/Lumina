import Foundation

struct LuminaAgenticRLSummaryPayload: Codable {
    let report: LuminaAgenticRLReport
    let taskIDs: [String]
}
