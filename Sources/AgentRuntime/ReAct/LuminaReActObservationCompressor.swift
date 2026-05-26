import Foundation

enum LuminaReActObservationCompressor {
    static func observation(
        from result: LuminaToolResult,
        permissionDecision: LuminaPermissionDecision? = nil,
        confirmed: Bool = false,
        maximumCharacters: Int
    ) -> LuminaReActObservation {
        var parts: [String] = []
        if case .requiresConfirmation? = permissionDecision {
            parts.append(confirmed ? "用户已确认执行该工具。" : "用户没有确认执行该工具。")
        }
        if !result.content.isEmpty {
            parts.append(result.content.compactMap(\.textForModelInput).joined(separator: "\n"))
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
