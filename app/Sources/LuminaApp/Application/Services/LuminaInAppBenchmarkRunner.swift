import LuminaAgentRuntime
import Foundation

@MainActor
final class LuminaInAppBenchmarkRunner {
    typealias ProgressHandler = @MainActor (LuminaBenchmarkSnapshot) -> Void

    private let services: AgentAppServices
    private let reportDirectory: URL

    init(services: AgentAppServices, reportDirectory: URL) {
        self.services = services
        self.reportDirectory = reportDirectory
    }

    func run(taskCount: Int = 200, progress: @escaping ProgressHandler) async -> LuminaBenchmarkReport {
        let tasks = LuminaBenchmarkSuite.makeTasks(count: taskCount)
        progress(LuminaBenchmarkSnapshot(state: .running, currentTask: "准备执行真实 App Benchmark", completed: 0, total: tasks.count))
        var results: [LuminaBenchmarkTaskResult] = []
        for task in tasks {
            if Task.isCancelled { break }
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: task.expectedTools.last))
            services.beginSession()
            let metricsMark = services.modelMetrics.mark()
            let (result, observedTimings) = await runSingleTask(task, completed: results.count, total: tasks.count, progress: progress)
            let actualTools = result.toolResults.map(\.toolName)
            let failure = result.status == .succeeded ? nil : result.plan.summary
            results.append(LuminaBenchmarkTaskResult(
                task: task,
                actualTools: actualTools,
                status: result.status.rawValue,
                totalMilliseconds: result.timing.totalMilliseconds,
                observedTimings: observedTimings,
                stepGenerationMilliseconds: result.timing.stepGenerationMilliseconds,
                toolMilliseconds: result.timing.toolExecutionMilliseconds,
                modelMetrics: services.modelMetrics.metrics(after: metricsMark),
                failureSummary: failure
            ))
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: actualTools.last ?? task.expectedTools.last))
        }
        let reportURLs = writeReport(results: results)
        let report = LuminaBenchmarkReport.make(results: results, jsonReportURL: reportURLs.json, markdownReportURL: reportURLs.markdown)
        progress(LuminaBenchmarkSnapshot(state: Task.isCancelled ? .cancelled : .finished, currentTask: "Benchmark 完成", completed: results.count, total: tasks.count, report: report))
        return report
    }

    private func runSingleTask(
        _ task: LuminaBenchmarkTask,
        completed: Int,
        total: Int,
        progress: @escaping ProgressHandler
    ) async -> (LuminaAgentRunResult, LuminaObservedRunTimings) {
        var finalResult: LuminaAgentRunResult?
        var observer = LuminaRunStreamObserver()
        var latestPromptTokens: Int?
        var latestSampledTokens = 0
        var latestOutputTokens = 0
        observer.start()
        for await event in services.runEvaluationStream(content: [.text(task.text)]) {
            if Task.isCancelled { break }
            observer.observe(event)
            if case let .stepGenerationProgress(stepGenerationProgress) = event {
                if let promptTokens = stepGenerationProgress.promptTokens {
                    latestPromptTokens = promptTokens
                }
                if let sampledTokens = stepGenerationProgress.sampledTokens {
                    latestSampledTokens = max(latestSampledTokens, sampledTokens)
                }
                latestOutputTokens = max(latestOutputTokens, stepGenerationProgress.outputTokens)
                let promptText = latestPromptTokens.map { " · prompt \($0) tok" } ?? ""
                let sampledText = latestOutputTokens == 0 && latestSampledTokens > 0 ? " · sampled \(latestSampledTokens) tok" : ""
                let outputText = latestOutputTokens > 0 ? " · output \(latestOutputTokens) tok" : sampledText
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · 模型生成中 \(Int(stepGenerationProgress.elapsedMilliseconds / 1_000))s\(promptText)\(outputText)",
                    completed: completed,
                    total: total,
                    latestTool: "model.generating"
                ))
            }
            if case let .actionProposed(call) = event {
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · action \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .confirmationRequired(call) = event {
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · 自动确认 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: "confirming.\(call.toolName)"
                ))
            }
            if case let .toolStarted(call) = event {
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · 执行 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .toolFinished(result) = event {
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · \(result.toolName) \(result.status.rawValue)",
                    completed: completed,
                    total: total,
                    latestTool: result.toolName
                ))
            }
            if case let .finished(result) = event {
                finalResult = result
            }
        }
        if let finalResult {
            return (finalResult, observer.finish(result: finalResult))
        }
        let cancelled = LuminaAgentRunResult(
            requestID: UUID(),
            plan: LuminaAgentPlan(summary: "Benchmark task cancelled before runtime finished.", toolCalls: []),
            toolResults: [],
            status: .cancelled
        )
        return (cancelled, observer.finish(result: cancelled))
    }

    private func writeReport(results: [LuminaBenchmarkTaskResult]) -> (json: URL?, markdown: URL?) {
        do {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970)
            let jsonURL = reportDirectory.appendingPathComponent("LuminaBenchmark-\(timestamp).json")
            let markdownURL = reportDirectory.appendingPathComponent("LuminaBenchmark-\(timestamp).md")
            let report = LuminaBenchmarkReport.make(results: results, jsonReportURL: jsonURL, markdownReportURL: markdownURL)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(report).write(to: jsonURL, options: .atomic)
            try markdown(report).write(to: markdownURL, atomically: true, encoding: .utf8)
            return (jsonURL, markdownURL)
        } catch {
            return (nil, nil)
        }
    }

    private func markdown(_ report: LuminaBenchmarkReport) -> String {
        let rows = report.results.prefix(200).map { result in
            "| \(result.taskID) | \(result.status) | \(format(result.f1)) | \(Int(result.activeRuntimeMilliseconds))ms | \(Int(result.wallClockMilliseconds))ms | \(Int(result.systemPermissionWaitMilliseconds))ms | \(result.actualTools.joined(separator: ", ")) | \(result.modelMetrics.count) |"
        }.joined(separator: "\n")
        return """
        # Lumina In-App Benchmark Report

        Generated: \(report.generatedAt)

        ## Summary
        - Tasks: \(report.completedCount)/\(report.taskCount)
        - Succeeded: \(report.succeededCount)
        - Failed: \(report.failedCount)
        - Exact tool match: \(format(report.exactToolMatch))
        - Micro precision: \(format(report.microPrecision))
        - Micro recall: \(format(report.microRecall))
        - Micro F1: \(format(report.microF1))
        - Active runtime p50/p95: \(Int(report.latencyP50Milliseconds))ms / \(Int(report.latencyP95Milliseconds))ms
        - Wall-clock p95: \(Int(report.wallClockP95Milliseconds))ms
        - Confirmation wait p95: \(Int(report.confirmationWaitP95Milliseconds))ms
        - System permission wait p95: \(Int(report.systemPermissionWaitP95Milliseconds))ms
        - Step generation p95: \(Int(report.stepGenerationP95Milliseconds))ms
        - Tool p95: \(Int(report.toolP95Milliseconds))ms
        - Memory access disabled: \(report.memoryAccessDisabled)

        ## Model Inference
        - Model invocations: \(report.modelInvocationCount)
        - TTFT p50/p95: \(optionalMilliseconds(report.modelTTFTP50Milliseconds)) / \(optionalMilliseconds(report.modelTTFTP95Milliseconds))
        - Decode tokens/s p50/p95: \(optionalNumber(report.modelTokensPerSecondP50)) / \(optionalNumber(report.modelTokensPerSecondP95))
        - Prompt tokens p95: \(optionalNumber(report.modelPromptTokensP95))
        - Output tokens p95: \(optionalNumber(report.modelOutputTokensP95))

        ## Tasks
        | Task | Status | Tool F1 | Active latency | Wall clock | Permission wait | Actual tools | Model calls |
        | --- | --- | ---: | ---: | ---: | ---: | --- | ---: |
        \(rows)
        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int(value))ms"
    }

    private func optionalNumber(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }
}
