import Foundation

public struct LuminaSummarizingReActContextCompactor: LuminaReActContextCompactor {
    public init() {}

    public func compact(_ request: LuminaReActCompactionRequest) async throws -> LuminaReActCompactionResult {
        try Task.checkCancellation()
        let preservedCount = max(0, request.preservedStepCount)
        let preserved = Array(request.trace.steps.suffix(preservedCount))
        let dropped = Array(request.trace.steps.dropLast(min(preservedCount, request.trace.steps.count)))
        guard !dropped.isEmpty else {
            return LuminaReActCompactionResult(
                trace: request.trace,
                summary: "",
                estimatedCharactersBefore: request.estimatedCharacters,
                estimatedCharactersAfter: request.estimatedCharacters
            )
        }

        let summary = Self.summary(
            for: dropped,
            loadedContext: request.loadedContext,
            maximumCharacters: request.maximumSummaryCharacters
        )
        let compactedObservation = LuminaReActObservation(
            toolName: "runtime.context_compaction",
            status: .succeeded,
            summary: summary
        )
        let compactedStep = LuminaReActStep.observation(compactedObservation)
        let compactedActions = dropped.filter { $0.kind == .action }.count
        let compactedTrace = LuminaReActTrace(
            steps: [compactedStep] + preserved,
            terminationReason: request.trace.terminationReason,
            compactedActionCount: request.trace.compactedActionCount + compactedActions,
            compactionCount: request.trace.compactionCount + 1
        )
        let estimatedAfter = LuminaReActContextWindowEstimator.estimateCharacters(
            request: request.agentRequest,
            schemas: request.availableTools,
            trace: compactedTrace,
            loadedContext: request.loadedContext
        )
        return LuminaReActCompactionResult(
            trace: compactedTrace,
            summary: summary,
            estimatedCharactersBefore: request.estimatedCharacters,
            estimatedCharactersAfter: estimatedAfter
        )
    }

    private static func summary(
        for steps: [LuminaReActStep],
        loadedContext: LuminaRuntimeContext,
        maximumCharacters: Int
    ) -> String {
        var lines: [String] = [
            "### Auto compacted ReAct context",
            "",
            "Older ReAct steps were compacted to keep the active context within budget.",
            "Preserve this as historical state; use tools for fresh data if needed."
        ]

        let observations = steps.compactMap(\.observation)
        if !observations.isEmpty {
            lines.append("")
            lines.append("#### Compacted observations")
            for observation in observations.suffix(8) {
                let status = observation.status.rawValue
                let summary = observation.summary
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append("- \(observation.toolName) [\(status)]: \(summary.prefix(360))")
            }
        }

        let actions = steps.compactMap(\.action)
        if !actions.isEmpty {
            lines.append("")
            lines.append("#### Compacted tool calls")
            let counts = Dictionary(grouping: actions, by: \.toolName).mapValues(\.count)
            for key in counts.keys.sorted() {
                lines.append("- \(key): \(counts[key] ?? 0)")
            }
        }

        if !loadedContext.sections.isEmpty {
            lines.append("")
            lines.append("#### Preloaded context references")
            for section in loadedContext.sections.prefix(6) {
                lines.append("- \(section.id): \(section.title) / \(section.source)")
            }
        }

        let text = lines.joined(separator: "\n")
        guard text.count > maximumCharacters else { return text }
        return String(text.prefix(maximumCharacters)) + "\n\n[compact summary truncated]"
    }
}
