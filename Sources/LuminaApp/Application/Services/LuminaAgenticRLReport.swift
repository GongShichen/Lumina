import Foundation

struct LuminaAgenticRLReport: Codable, Hashable {
    let generatedAt: Date
    let schemaVersion: String
    let taskCount: Int
    let completedCount: Int
    let succeededCount: Int
    let averageReward: Double
    let microPrecision: Double
    let microRecall: Double
    let microF1: Double
    let trajectoryJSONLURL: URL?
    let summaryJSONURL: URL?

    static func make(records: [LuminaAgenticRLTrajectoryRecord], trajectoryJSONLURL: URL?, summaryJSONURL: URL?) -> LuminaAgenticRLReport {
        var truePositive = 0
        var falsePositive = 0
        var falseNegative = 0
        for record in records {
            let expected = Set(record.task.expectedTools)
            let actual = Set(record.actualTools)
            truePositive += expected.intersection(actual).count
            falsePositive += actual.subtracting(expected).count
            falseNegative += expected.subtracting(actual).count
        }
        let precision = ratio(truePositive, truePositive + falsePositive)
        let recall = ratio(truePositive, truePositive + falseNegative)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let reward = records.isEmpty ? 0 : records.map(\.outcome.reward).reduce(0, +) / Double(records.count)
        return LuminaAgenticRLReport(
            generatedAt: Date(),
            schemaVersion: "lumina.agentic_rl.v1",
            taskCount: records.count,
            completedCount: records.count,
            succeededCount: records.filter { $0.outcome.status == "succeeded" }.count,
            averageReward: reward,
            microPrecision: precision,
            microRecall: recall,
            microF1: f1,
            trajectoryJSONLURL: trajectoryJSONLURL,
            summaryJSONURL: summaryJSONURL
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}
