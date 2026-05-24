import Foundation

enum LuminaReActObservationCompressor {
    static func observation(from result: LuminaToolResult, maximumCharacters: Int) -> LuminaReActObservation {
        var parts: [String] = []
        if !result.content.isEmpty {
            parts.append(result.content.compactMap(\.textForPlanning).joined(separator: "\n"))
        }
        if parts.isEmpty, !result.output.isEmpty {
            parts.append("工具已返回结构化结果。")
        }
        if let error = result.errorMessage {
            parts.append(error)
        }
        let raw = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = String(raw.prefix(maximumCharacters))
        return LuminaReActObservation(
            toolName: result.toolName,
            status: result.status,
            summary: summary.isEmpty ? result.status.rawValue : summary,
            errorMessage: result.errorMessage
        )
    }
}
