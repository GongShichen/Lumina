import PersonalMemory
import SwiftUI

struct RuntimeStatusScreen: View {
    let stats: LuminaMemoryIndexStats
    let modelReadiness: LuminaModelReadinessSnapshot
    let benchmarkSnapshot: LuminaBenchmarkSnapshot
    let runBenchmark: () -> Void
    let cancelBenchmark: () -> Void

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LuminaSectionHeader(title: "Privacy & Trust", subtitle: "把技术细节收起来，但把控制权交给你")
                    LuminaPanel {
                        VStack(alignment: .leading, spacing: 12) {
                            RuntimeCapabilityRow(title: "端侧理解", value: "\(modelReadiness.modelState.displayName) · \(modelReadiness.modelSource)", icon: "iphone.gen3")
                            RuntimeCapabilityRow(title: "模型说明", value: modelReadiness.modelMessage, icon: "cpu")
                            RuntimeCapabilityRow(title: "Embedding", value: "\(modelReadiness.embeddingState.displayName) · \(modelReadiness.embeddingSource)", icon: "point.3.connected.trianglepath.dotted")
                            RuntimeCapabilityRow(title: "私人记忆", value: "\(stats.documentCount) docs / \(stats.chunkCount) fragments，只回传必要摘要。", icon: "brain.head.profile")
                            RuntimeCapabilityRow(title: "执行前确认", value: "创建提醒、写账、日历变更等都会先弹出确认。", icon: "checkmark.shield.fill")
                            RuntimeCapabilityRow(title: "可解释过程", value: "Thinking、Checking memory、Permission、Done 以友好步骤展示。", icon: "list.bullet.clipboard")
                            RuntimeCapabilityRow(title: "完整回复", value: "支持流式 Markdown 与多模态内容输出。", icon: "text.bubble.fill")
                        }
                    }
                    benchmarkPanel
                }
                .padding(16)
            }
        }
        .navigationTitle("Trust")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var benchmarkPanel: some View {
        LuminaPanel {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "speedometer")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(LuminaTheme.deepInk)
                        .frame(width: 42, height: 42)
                        .background(LuminaTheme.softAmber.opacity(0.45), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text("真实任务 Benchmark")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(LuminaTheme.ink)
                        Text("200 条 `LuminaTest` 任务会直接进入 App 内 ReAct runtime，真实调用工具、权限、确认与审计链路。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                ProgressView(value: benchmarkSnapshot.progress)
                    .tint(LuminaTheme.amber)

                HStack {
                    LuminaStatusPill(
                        title: "Progress",
                        value: "\(benchmarkSnapshot.completed)/\(benchmarkSnapshot.total)",
                        systemImage: "chart.line.uptrend.xyaxis",
                        tint: LuminaTheme.amber
                    )
                    LuminaStatusPill(
                        title: "Activity",
                        value: benchmarkActivityText,
                        systemImage: "hammer.fill",
                        tint: LuminaTheme.aqua
                    )
                }

                if !benchmarkSnapshot.currentTask.isEmpty {
                    Text(benchmarkSnapshot.currentTask)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(LuminaTheme.ink)
                        .lineLimit(3)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.white.opacity(0.54), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }

                if let report = benchmarkSnapshot.report {
                    benchmarkReportSummary(report)
                }

                Button {
                    benchmarkSnapshot.isRunning ? cancelBenchmark() : runBenchmark()
                } label: {
                    HStack {
                        Image(systemName: benchmarkSnapshot.isRunning ? "stop.fill" : "play.fill")
                        Text(benchmarkSnapshot.isRunning ? "停止 Benchmark" : "运行 200 条真实 Benchmark")
                            .fontWeight(.semibold)
                        Spacer()
                        Text("App runtime")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(benchmarkSnapshot.isRunning ? LuminaTheme.rose : LuminaTheme.deepInk)
            }
        }
    }

    private var benchmarkActivityText: String {
        guard let rawValue = benchmarkSnapshot.latestTool?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return benchmarkSnapshot.isRunning ? "模型生成" : "等待"
        }
        if rawValue == "model.generating" || rawValue.hasPrefix("model.") {
            return "模型生成"
        }
        if rawValue.hasPrefix("confirming.") {
            return "确认 \(String(rawValue.dropFirst("confirming.".count)))"
        }
        return rawValue
    }

    private func benchmarkReportSummary(_ report: LuminaBenchmarkReport) -> some View {
        #if DEBUG
        BenchmarkReportUICoverage.assertAllMetricsMapped()
        #endif

        return VStack(alignment: .leading, spacing: 12) {
            Text("最近报告")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LuminaTheme.ink)

            benchmarkMetricSection("Outcome", metrics: [
                BenchmarkMetric(title: "Tasks", value: "\(report.completedCount)/\(report.taskCount)", caption: "completed / total", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Succeeded", value: "\(report.outcomePassedCount)", caption: "任务完成数", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Failed", value: "\(report.failedCount)", caption: "outcome status", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Outcome", value: percent(report.outcomePassRate), caption: "\(report.outcomePassedCount)/\(report.completedCount)", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Pass@1", value: percent(report.passAt1Rate), caption: "\(report.passAt1Count)/\(report.completedCount) single sample", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Strict", value: percent(report.strictToolPassRate), caption: "\(report.strictToolPassCount)/\(report.completedCount) exact tools", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Semantic", value: percent(report.semanticPassRate), caption: "\(report.semanticPassedCount)/\(report.completedCount) compat", tint: LuminaTheme.aqua)
            ])

            benchmarkMetricSection("Tool Discipline", metrics: [
                BenchmarkMetric(title: "F1", value: percent(report.microF1), caption: "tool micro F1", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Precision", value: percent(report.microPrecision), caption: "tool precision", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Recall", value: percent(report.microRecall), caption: "tool recall", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Exact", value: percent(report.exactToolMatch), caption: "工具集合完全匹配", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Exec@1", value: percent(report.toolExecutionAt1Rate), caption: "\(report.toolExecutionAt1Count) tool task(s)", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Attempts", value: "\(report.toolAttemptCount)", caption: "all observations", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Executions", value: "\(report.toolExecutionCount)", caption: "non-replay", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Replays", value: "\(report.toolReplayCount)", caption: "dedup observations", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Missing", value: "\(report.missingToolCount)", caption: "expected not seen", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Unexpected", value: "\(report.unexpectedToolCount)", caption: "outside expected", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Failed", value: "\(report.failedToolCount)", caption: "failed tools", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Replayed", value: "\(report.replayedToolCount)", caption: "tool replay total", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Ordered", value: percent(report.orderedToolMatchRate), caption: "\(report.orderedToolMatchCount) ordered matches", tint: LuminaTheme.deepInk)
            ])

            benchmarkMetricSection("Runtime Contract", metrics: [
                BenchmarkMetric(title: "Normalize", value: "\(report.normalizationFailureCount)", caption: "XML/JSON 修复失败", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Schema", value: "\(report.schemaValidationFailureCount)", caption: "入参校验失败", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Unknown", value: "\(report.unknownToolRejectCount)", caption: "未知工具拒绝", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Obs Reject", value: "\(report.modelOwnedObservationRejectCount)", caption: "模型伪 observation", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Retry", value: "\(report.retryCount)", caption: "runtime retry", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Fallback", value: "\(report.fallbackCount)", caption: "fallback count", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Tool Fail", value: "\(report.toolFailureCount)", caption: "工具执行失败", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Multi Gen", value: "\(report.multiToolGenerationCount)", caption: "multi-tool generations", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Multi Calls", value: "\(report.multiToolCallCount)", caption: "calls in multi batches", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Multi Partial", value: "\(report.multiToolPartialFailureCount)", caption: "partial batch failures", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Internal Ignored", value: "\(report.internalToolIgnoredCount)", caption: "runtime.* ignored", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Batch Stops", value: "\(report.sideEffectBatchStopCount)", caption: "side-effect stops", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Contract", value: "\(report.runtimeContractFailureCount)", caption: percent(report.runtimeContractFailureRate), tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Validated", value: "\(report.modelGenerationValidatedCount)", caption: "model generations", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Special", value: "\(report.modelStreamContainsSpecialTokensCount)", caption: "MiniCPM token streams", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Canonical", value: "\(report.hostReturnedCanonicalStepCount)", caption: "host steps", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Extracted", value: "\(report.coreExtractedSpecialTokenStepCount)", caption: "core parsed tags", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Tool/Result", value: "\(report.canonicalToolUseStepCount)/\(report.canonicalResultStepCount)", caption: "canonical steps", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Legacy", value: "\(report.legacyOutputSchemaObservedCount)", caption: "old schema observed", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Obs", value: "\(report.runtimeObservationCount)", caption: "runtime observations", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Results", value: "\(report.resultGeneratedCount)", caption: "result steps", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Hooks", value: "\(report.hookEventCount)", caption: "hook events", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Schema Saved", value: "\(report.schemaTokensSavedEstimate)", caption: "token estimate", tint: LuminaTheme.deepInk)
            ])

            benchmarkMetricSection("Performance", metrics: [
                BenchmarkMetric(title: "Active P50", value: milliseconds(report.latencyP50Milliseconds), caption: "runtime active", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Active P95", value: milliseconds(report.latencyP95Milliseconds), caption: "runtime active", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Wall P95", value: milliseconds(report.wallClockP95Milliseconds), caption: "wall-clock", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Confirm P95", value: milliseconds(report.confirmationWaitP95Milliseconds), caption: "confirmation wait", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Permission P95", value: milliseconds(report.systemPermissionWaitP95Milliseconds), caption: "system permission", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Gen P95", value: milliseconds(report.stepGenerationP95Milliseconds), caption: "model step", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Tool P95", value: milliseconds(report.toolP95Milliseconds), caption: "tool latency", tint: LuminaTheme.mint)
            ])

            benchmarkMetricSection("Model", metrics: [
                BenchmarkMetric(title: "Calls", value: "\(report.modelInvocationCount)", caption: "model invocations", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Local", value: "\(report.localModelInvocationCount)", caption: "local calls", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Remote", value: "\(report.remoteModelInvocationCount)", caption: "remote calls", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "TTFT P50", value: milliseconds(report.modelTTFTP50Milliseconds), caption: "time to first token", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "TTFT P95", value: milliseconds(report.modelTTFTP95Milliseconds), caption: "time to first token", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Tok/s P50", value: decimal(report.modelTokensPerSecondP50), caption: "decode speed", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Tok/s P95", value: decimal(report.modelTokensPerSecondP95), caption: "decode speed", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Prompt P95", value: decimal(report.modelPromptTokensP95), caption: "prompt tokens", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Output P95", value: decimal(report.modelOutputTokensP95), caption: "output tokens", tint: LuminaTheme.mint)
            ])

            benchmarkMetricSection("Tool Loading", metrics: [
                BenchmarkMetric(title: "Tool Hit", value: percent(report.toolDiscoveryHitRate), caption: "\(report.toolLoadingSearchCount) search(es)", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Deferred Unk", value: percent(report.deferredUnknownToolRate), caption: "deferred unknown rate", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Tool Search", value: "\(report.toolLoadingSearchCount)", caption: "deferred searches", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Tool Load", value: "\(report.toolLoadingLoadedCount)", caption: "loaded", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Tool Failed", value: "\(report.toolLoadingLoadFailedCount)", caption: "load failed", tint: LuminaTheme.rose)
            ])

            benchmarkMetricSection("Context Loading", metrics: [
                BenchmarkMetric(title: "Ctx", value: "\(report.contextLoadingCatalogEmittedCount)", caption: "catalog emitted", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Ctx Search", value: "\(report.contextLoadingSearchCount)", caption: "searches", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Ctx Load", value: "\(report.contextLoadingLoadedCount)", caption: "sections loaded", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Range", value: "\(report.contextLoadingRangeLoadedCount)", caption: "ranges loaded", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Ctx Hit", value: percent(report.contextLoadingHitRate), caption: "\(report.contextLoadingSearchCount) search(es)", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Ctx Cache", value: "\(report.contextLoadingCacheHitCount)", caption: "cache hits", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "Ctx Failed", value: "\(report.contextLoadingLoadFailedCount)", caption: "load failed", tint: LuminaTheme.rose),
                BenchmarkMetric(title: "Ctx Tokens", value: "\(report.contextLoadingTokensEstimate)", caption: "token estimate", tint: LuminaTheme.mint)
            ])

            benchmarkMetricSection("Metadata", metrics: [
                BenchmarkMetric(title: "Generated", value: shortDate(report.generatedAt), caption: "report time", tint: LuminaTheme.amber),
                BenchmarkMetric(title: "Model", value: report.localModelDisplayName ?? "unknown", caption: report.localModelSelectionRawValue ?? "unknown", tint: LuminaTheme.mint),
                BenchmarkMetric(title: "Source", value: report.modelSource ?? "unknown", caption: "runtime model", tint: LuminaTheme.aqua),
                BenchmarkMetric(title: "Memory", value: report.memoryAccessDisabled ? "disabled" : "enabled", caption: "benchmark access", tint: LuminaTheme.lavender),
                BenchmarkMetric(title: "JSON", value: report.jsonReportURL?.lastPathComponent ?? "n/a", caption: "export", tint: LuminaTheme.deepInk),
                BenchmarkMetric(title: "Markdown", value: report.markdownReportURL?.lastPathComponent ?? "n/a", caption: "export", tint: LuminaTheme.rose)
            ])

            benchmarkTaskSummary(report)
        }
    }

    private func benchmarkTaskSummary(_ report: LuminaBenchmarkReport) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.results.prefix(200)) { result in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(result.taskID)
                                .font(.caption.weight(.bold))
                            Text(result.status)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(result.outcomePassed ? LuminaTheme.mint : LuminaTheme.rose)
                            Spacer()
                            Text(result.strictToolPassed ? "strict" : "non-strict")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(result.text)
                            .font(.caption2)
                            .foregroundStyle(LuminaTheme.ink)
                            .lineLimit(2)
                        Text("runtime=\(result.runtimeStatus) termination=\(result.terminationReason ?? "none") latency=\(milliseconds(result.activeRuntimeMilliseconds)) modelCalls=\(result.modelMetrics.count)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        let detail = [
                            result.outcomeFailures.isEmpty ? nil : "outcome: \(result.outcomeFailures.joined(separator: "; "))",
                            result.toolDiagnosticsSummary.map { "tools: \($0)" }
                        ].compactMap { $0 }.joined(separator: " | ")
                        if !detail.isEmpty {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.42), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        } label: {
            Text("Task Details (\(report.results.count))")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
        }
    }

    private func benchmarkMetricSection(_ title: String, metrics: [BenchmarkMetric]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                ForEach(metrics) { metric in
                    LuminaMetricTile(title: metric.title, value: metric.value, caption: metric.caption, tint: metric.tint)
                }
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int(value.rounded()))ms"
    }

    private func decimal(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.1f", value)
    }

    private func shortDate(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct BenchmarkMetric: Identifiable {
    var id: String { "\(title)-\(caption)" }
    let title: String
    let value: String
    let caption: String
    let tint: Color
}

#if DEBUG
private enum BenchmarkReportUICoverage {
    private static let mappedKeys: Set<LuminaBenchmarkReport.CodingKeys> = [
        .generatedAt,
        .localModelSelectionRawValue,
        .localModelDisplayName,
        .modelSource,
        .taskCount,
        .completedCount,
        .succeededCount,
        .failedCount,
        .outcomePassedCount,
        .outcomePassRate,
        .passAt1Count,
        .passAt1Rate,
        .strictToolPassCount,
        .strictToolPassRate,
        .toolExecutionAt1Count,
        .toolExecutionAt1Rate,
        .semanticPassedCount,
        .semanticPassRate,
        .missingToolCount,
        .unexpectedToolCount,
        .failedToolCount,
        .replayedToolCount,
        .orderedToolMatchCount,
        .orderedToolMatchRate,
        .toolAttemptCount,
        .toolExecutionCount,
        .toolReplayCount,
        .exactToolMatch,
        .microPrecision,
        .microRecall,
        .microF1,
        .latencyP50Milliseconds,
        .latencyP95Milliseconds,
        .wallClockP95Milliseconds,
        .confirmationWaitP95Milliseconds,
        .systemPermissionWaitP95Milliseconds,
        .stepGenerationP95Milliseconds,
        .toolP95Milliseconds,
        .modelInvocationCount,
        .modelTTFTP50Milliseconds,
        .modelTTFTP95Milliseconds,
        .modelTokensPerSecondP50,
        .modelTokensPerSecondP95,
        .modelPromptTokensP95,
        .modelOutputTokensP95,
        .runtimeContractFailureCount,
        .runtimeContractFailureRate,
        .normalizationFailureCount,
        .schemaValidationFailureCount,
        .modelOwnedObservationRejectCount,
        .unknownToolRejectCount,
        .retryCount,
        .fallbackCount,
        .remoteModelInvocationCount,
        .localModelInvocationCount,
        .modelGenerationValidatedCount,
        .modelStreamContainsSpecialTokensCount,
        .hostReturnedCanonicalStepCount,
        .coreExtractedSpecialTokenStepCount,
        .canonicalToolUseStepCount,
        .canonicalResultStepCount,
        .legacyOutputSchemaObservedCount,
        .runtimeObservationCount,
        .resultGeneratedCount,
        .hookEventCount,
        .toolFailureCount,
        .multiToolGenerationCount,
        .multiToolCallCount,
        .multiToolPartialFailureCount,
        .internalToolIgnoredCount,
        .sideEffectBatchStopCount,
        .schemaTokensSavedEstimate,
        .toolDiscoveryHitRate,
        .deferredUnknownToolRate,
        .toolLoadingSearchCount,
        .toolLoadingLoadedCount,
        .toolLoadingLoadFailedCount,
        .contextLoadingCatalogEmittedCount,
        .contextLoadingSearchCount,
        .contextLoadingLoadedCount,
        .contextLoadingRangeLoadedCount,
        .contextLoadingCacheHitCount,
        .contextLoadingLoadFailedCount,
        .contextLoadingHitRate,
        .contextLoadingTokensEstimate,
        .memoryAccessDisabled,
        .results,
        .jsonReportURL,
        .markdownReportURL
    ]

    static func assertAllMetricsMapped(
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        let missing = Set(LuminaBenchmarkReport.CodingKeys.allCases).subtracting(mappedKeys)
        assert(missing.isEmpty, "Unmapped benchmark report metrics: \(missing.map(\.rawValue).sorted().joined(separator: ", "))", file: file, line: line)
    }
}
#endif
