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
                        title: "Tool",
                        value: benchmarkSnapshot.latestTool ?? "waiting",
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

    private func benchmarkReportSummary(_ report: LuminaBenchmarkReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近报告")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(LuminaTheme.ink)
            HStack(spacing: 10) {
                LuminaMetricTile(title: "F1", value: percent(report.microF1), caption: "tool micro F1", tint: LuminaTheme.mint)
                LuminaMetricTile(title: "Recall", value: percent(report.microRecall), caption: "tool recall", tint: LuminaTheme.aqua)
            }
            HStack(spacing: 10) {
                LuminaMetricTile(title: "P95", value: "\(Int(report.latencyP95Milliseconds))ms", caption: "end-to-end", tint: LuminaTheme.amber)
                LuminaMetricTile(title: "Pass@1", value: percent(report.passAt1Rate), caption: "\(report.passAt1Count)/\(report.completedCount)", tint: LuminaTheme.lavender)
            }
            HStack(spacing: 10) {
                LuminaMetricTile(title: "Exec@1", value: percent(report.toolExecutionAt1Rate), caption: "\(report.toolExecutionAt1Count) tool task(s)", tint: LuminaTheme.rose)
                LuminaMetricTile(title: "Ctx", value: "\(report.contextLoadingCatalogEmittedCount)", caption: "catalog emitted", tint: LuminaTheme.mint)
            }
            HStack(spacing: 10) {
                LuminaMetricTile(title: "Ctx Load", value: "\(report.contextLoadingLoadedCount + report.contextLoadingRangeLoadedCount)", caption: "sections loaded", tint: LuminaTheme.aqua)
                LuminaMetricTile(title: "Ctx Hit", value: percent(report.contextLoadingHitRate), caption: "\(report.contextLoadingSearchCount) search(es)", tint: LuminaTheme.amber)
            }
            if let url = report.markdownReportURL ?? report.jsonReportURL {
                Text("已导出：\(url.lastPathComponent)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}
