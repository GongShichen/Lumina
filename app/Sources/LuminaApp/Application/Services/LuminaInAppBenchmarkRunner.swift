import LuminaAgentRuntime
import LuminaAppCore
import LuminaModelRuntime
import Contacts
import CoreLocation
@preconcurrency import EventKit
import Foundation
import UserNotifications

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
        let traceLogger = LuminaBenchmarkTraceLogger(reportDirectory: reportDirectory)
        let runModelSelection = services.localModelSelection.selection
        let selectedModel = selectedModelDescriptor(for: runModelSelection)
        let readinessModelSourceAtStart = services.modelReadiness.snapshot.modelSource
        await traceLogger.record("benchmark_started", fields: [
            "taskCount": "\(tasks.count)",
            "localModelSelection": runModelSelection.rawValue,
            "localModelDisplayName": runModelSelection.displayName,
            "initialModelSource": selectedModel.source,
            "selectedModelSource": selectedModel.source,
            "selectedModelBundleName": runModelSelection.bundleDirectoryName,
            "selectedModelBundlePath": selectedModel.bundlePath,
            "readinessModelSourceAtStart": readinessModelSourceAtStart,
            "process": ProcessInfo.processInfo.processName,
            "pid": "\(ProcessInfo.processInfo.processIdentifier)",
            "executable": Bundle.main.executableURL?.path ?? "",
            "bundlePath": Bundle.main.bundleURL.path,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "reportDirectory": reportDirectory.path
        ])
        progress(LuminaBenchmarkSnapshot(state: .running, currentTask: "准备执行真实 App Benchmark", completed: 0, total: tasks.count))
        await prepareBenchmarkFixtures(traceLogger: traceLogger)
        var results: [LuminaBenchmarkTaskResult] = []
        for (taskIndex, task) in tasks.enumerated() {
            if Task.isCancelled { break }
            await traceLogger.record("task_started", fields: [
                "taskID": task.id,
                "taskIndex": "\(taskIndex + 1)",
                "text": task.text,
                "category": task.category,
                "expectedTools": task.expectedTools.joined(separator: ",")
            ])
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: task.expectedTools.last))
            services.beginSession()
            let metricsMark = services.modelMetrics.mark()
            let (result, observedTimings) = await runSingleTask(task, completed: results.count, total: tasks.count, traceLogger: traceLogger, progress: progress)
            let modelMetrics = services.modelMetrics.metrics(after: metricsMark)
            let toolAttempts = result.toolResults.map(\.toolName)
            let toolReplays = result.toolResults.filter { $0.output["replayed"]?.boolValue == true }.map(\.toolName)
            let actualTools = result.toolResults.filter { $0.output["replayed"]?.boolValue != true }.map(\.toolName)
            let expectedSet = Set(task.expectedTools)
            let actualSet = Set(actualTools)
            let missingTools = expectedSet.subtracting(actualSet).sorted()
            let unexpectedTools = actualSet.subtracting(expectedSet).sorted()
            let semanticFailures = await LuminaBenchmarkSemanticEvaluator.evaluate(task: task, result: result, services: services)
            let toolMismatchSummary = missingTools.isEmpty && unexpectedTools.isEmpty
                ? nil
                : "Expected tools did not match executions. missing=\(missingTools.joined(separator: ",")); unexpected=\(unexpectedTools.joined(separator: ","))"
            let semanticSummary = semanticFailures.isEmpty ? nil : "Semantic validation failed: \(semanticFailures.joined(separator: "; "))"
            let failure = [result.status == .succeeded ? nil : result.plan.summary, toolMismatchSummary, semanticSummary]
                .compactMap { $0 }
                .joined(separator: "\n")
            let taskResult = LuminaBenchmarkTaskResult(
                task: task,
                toolAttempts: toolAttempts,
                actualTools: actualTools,
                toolReplays: toolReplays,
                semanticFailures: semanticFailures,
                status: result.status.rawValue,
                totalMilliseconds: result.timing.totalMilliseconds,
                observedTimings: observedTimings,
                stepGenerationMilliseconds: result.timing.stepGenerationMilliseconds,
                toolMilliseconds: result.timing.toolExecutionMilliseconds,
                modelMetrics: modelMetrics,
                runtimeMetrics: runtimeMetrics(observedTimings: observedTimings, modelMetrics: modelMetrics),
                failureSummary: failure
            )
            results.append(taskResult)
            await traceLogger.record("task_finished", fields: [
                "taskID": task.id,
                "runtimeStatus": result.status.rawValue,
                "status": taskResult.status,
                "expectedToolsEffective": task.expectedTools.joined(separator: ","),
                "missingTools": missingTools.joined(separator: ","),
                "unexpectedTools": unexpectedTools.joined(separator: ","),
                "semanticPassed": "\(taskResult.semanticPassed)",
                "semanticFailures": semanticFailures.joined(separator: "; "),
                "attempts": toolAttempts.joined(separator: ","),
                "executions": actualTools.joined(separator: ","),
                "replays": toolReplays.joined(separator: ","),
                "wallClockMs": String(format: "%.1f", observedTimings.wallClockMilliseconds),
                "activeMs": String(format: "%.1f", observedTimings.activeRuntimeMilliseconds),
                "modelMs": String(format: "%.1f", result.timing.stepGenerationMilliseconds),
                "toolMs": String(format: "%.1f", result.timing.toolExecutionMilliseconds),
                "result": result.plan.summary.truncated(to: 4_000),
                "toolResultCount": "\(result.toolResults.count)",
                "normalizationFailures": "\(taskResult.runtimeMetrics.normalizationFailureCount)",
                "schemaValidationFailures": "\(taskResult.runtimeMetrics.schemaValidationFailureCount)",
                "modelOwnedObservationRejects": "\(taskResult.runtimeMetrics.modelOwnedObservationRejectCount)",
                "unknownToolRejects": "\(taskResult.runtimeMetrics.unknownToolRejectCount)",
                "retries": "\(taskResult.runtimeMetrics.retryCount)",
                "fallbacks": "\(taskResult.runtimeMetrics.fallbackCount)",
                "remoteModelCalls": "\(taskResult.runtimeMetrics.remoteModelInvocationCount)",
                "localModelCalls": "\(taskResult.runtimeMetrics.localModelInvocationCount)"
            ])
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: actualTools.last ?? task.expectedTools.last))
        }
        let reportURLs = writeReport(results: results, runModelSelection: runModelSelection, selectedModelSource: selectedModel.source)
        let report = LuminaBenchmarkReport.make(
            results: results,
            jsonReportURL: reportURLs.json,
            markdownReportURL: reportURLs.markdown,
            localModelSelectionRawValue: runModelSelection.rawValue,
            localModelDisplayName: runModelSelection.displayName,
            modelSource: selectedModel.source
        )
        await traceLogger.record("benchmark_finished", fields: [
            "completed": "\(results.count)",
            "localModelSelection": runModelSelection.rawValue,
            "localModelDisplayName": runModelSelection.displayName,
            "finalModelSource": selectedModel.source,
            "readinessModelSourceAtEnd": services.modelReadiness.snapshot.modelSource,
            "report": reportURLs.json?.path ?? "",
            "trace": await traceLogger.fileURL.path
        ])
        progress(LuminaBenchmarkSnapshot(state: Task.isCancelled ? .cancelled : .finished, currentTask: "Benchmark 完成", completed: results.count, total: tasks.count, report: report))
        return report
    }

    private func runtimeMetrics(
        observedTimings: LuminaObservedRunTimings,
        modelMetrics: [LuminaModelInferenceMetrics]
    ) -> LuminaBenchmarkRuntimeMetrics {
        var metrics = observedTimings.runtimeMetrics
        metrics.remoteModelInvocationCount = modelMetrics.filter { $0.computeUnits.localizedCaseInsensitiveContains("remote") }.count
        metrics.localModelInvocationCount = modelMetrics.count - metrics.remoteModelInvocationCount
        if services.modelReadiness.snapshot.lastRunUsedFallback {
            metrics.fallbackCount = max(metrics.fallbackCount, 1)
        }
        return metrics
    }

    private func runSingleTask(
        _ task: LuminaBenchmarkTask,
        completed: Int,
        total: Int,
        traceLogger: LuminaBenchmarkTraceLogger,
        progress: @escaping ProgressHandler
    ) async -> (LuminaAgentRunResult, LuminaObservedRunTimings) {
        var runResult: LuminaAgentRunResult?
        var observer = LuminaRunStreamObserver()
        var latestPromptTokens: Int?
        var latestSampledTokens = 0
        var latestOutputTokens = 0
        var latestActivity = "模型生成"
        let taskStartedAt = ContinuousClock.now
        observer.start()
        for await event in services.runEvaluationStream(task: task) {
            if Task.isCancelled { break }
            observer.observe(event)
            await logEvent(event, task: task, traceLogger: traceLogger)
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
                    currentTask: "\(task.text) · 模型生成中 \(Self.elapsedText(since: taskStartedAt))\(promptText)\(outputText)",
                    completed: completed,
                    total: total,
                    latestTool: latestActivity
                ))
            }
            if case let .actionProposed(call) = event {
                latestActivity = call.toolName
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · action \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .confirmationRequired(call) = event {
                latestActivity = "确认 \(call.toolName)"
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · 自动确认 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: latestActivity
                ))
            }
            if case let .toolStarted(call) = event {
                latestActivity = call.toolName
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · 执行 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .toolFinished(result) = event {
                latestActivity = result.toolName
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · \(result.toolName) \(result.status.rawValue)",
                    completed: completed,
                    total: total,
                    latestTool: result.toolName
                ))
            }
            if case let .finished(result) = event {
                runResult = result
            }
        }
        if let runResult {
            return (runResult, observer.finish(result: runResult))
        }
        let cancelled = LuminaAgentRunResult(
            requestID: UUID(),
            plan: LuminaAgentPlan(summary: "Benchmark task cancelled before runtime finished.", toolCalls: []),
            toolResults: [],
            status: .cancelled
        )
        return (cancelled, observer.finish(result: cancelled))
    }

    private func logEvent(_ event: LuminaAgentRunEvent, task: LuminaBenchmarkTask, traceLogger: LuminaBenchmarkTraceLogger) async {
        var fields: [String: String] = ["taskID": task.id]
        switch event {
        case let .stepGenerationProgress(progress):
            fields["phase"] = progress.message
            fields["elapsedMs"] = String(format: "%.1f", progress.elapsedMilliseconds)
            fields["promptTokens"] = progress.promptTokens.map(String.init) ?? ""
            fields["sampledTokens"] = progress.sampledTokens.map(String.init) ?? ""
            fields["outputTokens"] = "\(progress.outputTokens)"
            fields["partialOutput"] = progress.partialOutput?.truncated(to: 4_000) ?? ""
            await traceLogger.record("model_progress", fields: fields)
        case let .actionProposed(call):
            fields["toolName"] = call.toolName
            fields["arguments"] = call.arguments.compactModelTraceValue.truncated(to: 1_200)
            await traceLogger.record("action_proposed", fields: fields)
        case let .toolStarted(call):
            fields["toolName"] = call.toolName
            fields["arguments"] = call.arguments.compactModelTraceValue.truncated(to: 1_200)
            await traceLogger.record("tool_started", fields: fields)
        case let .toolFinished(result):
            fields["toolName"] = result.toolName
            fields["status"] = result.status.rawValue
            fields["error"] = result.errorMessage ?? ""
            fields["output"] = result.output.compactModelTraceValue.truncated(to: 2_000)
            await traceLogger.record("tool_finished", fields: fields)
        case let .observationCreated(observation):
            fields["toolName"] = observation.toolName
            fields["status"] = observation.status.rawValue
            fields["replayed"] = "\(observation.replayed)"
            fields["duplicateOf"] = observation.duplicateOf ?? ""
            fields["summary"] = observation.summary.truncated(to: 2_000)
            await traceLogger.record("observation_created", fields: fields)
        case let .resultGenerated(markdown):
            fields["markdown"] = markdown.truncated(to: 4_000)
            await traceLogger.record("result_generated", fields: fields)
        case let .finished(result):
            fields["status"] = result.status.rawValue
            fields["summary"] = result.plan.summary.truncated(to: 4_000)
            fields["toolResults"] = result.toolResults.map(\.toolName).joined(separator: ",")
            await traceLogger.record("run_finished", fields: fields)
        case let .hookAnnotated(key, value):
            fields["key"] = key
            fields["value"] = Self.traceString(for: value).truncated(to: 12_000)
            await traceLogger.record("runtime_event", fields: fields)
        case let .confirmationRequired(call):
            fields["toolName"] = call.toolName
            await traceLogger.record("confirmation_required", fields: fields)
        case let .confirmationResolved(call, confirmed):
            fields["toolName"] = call.toolName
            fields["confirmed"] = "\(confirmed)"
            await traceLogger.record("confirmation_resolved", fields: fields)
        default:
            break
        }
    }

    private static func elapsedText(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: ContinuousClock.now)
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1fs", milliseconds / 1_000)
    }

    private static func traceString(for value: LuminaJSONValue) -> String {
        if case let .string(string) = value {
            return string
        }
        return value.compactModelTraceValue
    }

    private func selectedModelDescriptor(for selection: LuminaLocalModelSelection) -> (source: String, bundlePath: String) {
        guard let url = selectedModelURL(for: selection) else {
            return (selection.displayName, "")
        }
        guard let info = try? LuminaMiniCPMV46ModelBundleInfo.inspect(directory: url, expectedContextLength: 16_000) else {
            return (selection.displayName, url.path)
        }
        return (
            "\(selection.displayName) · MiniCPM-V 4.6 GGUF · \(info.contextLength) ctx · \(info.quantization)",
            url.path
        )
    }

    private func selectedModelURL(for selection: LuminaLocalModelSelection) -> URL? {
        let environmentKeys: [String]
        let bundleCandidates: [String]
        switch selection {
        case .original:
            environmentKeys = ["LUMINA_MINICPMV46_ORIGINAL_MODEL", "LUMINA_MINICPMV46_MODEL"]
            bundleCandidates = ["MiniCPMV46ReActModel", "MiniCPMV46Model"]
        case .agenticDPO:
            environmentKeys = ["LUMINA_MINICPMV46_AGENTIC_DPO_MODEL"]
            bundleCandidates = ["MiniCPMV46ReActModel-AgenticSFTDPO-Q8", "MiniCPMV46AgenticDPOReActModel", "MiniCPMV46AgenticDPOModel"]
        }

        for key in environmentKeys {
            guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { continue }
            let url = URL(fileURLWithPath: value)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        for candidate in bundleCandidates {
            if let url = Bundle.main.resourceURL?.appendingPathComponent("Models/\(candidate)"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private func writeReport(
        results: [LuminaBenchmarkTaskResult],
        runModelSelection: LuminaLocalModelSelection,
        selectedModelSource: String
    ) -> (json: URL?, markdown: URL?) {
        do {
            try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970)
            let jsonURL = reportDirectory.appendingPathComponent("LuminaBenchmark-\(timestamp).json")
            let markdownURL = reportDirectory.appendingPathComponent("LuminaBenchmark-\(timestamp).md")
            let report = LuminaBenchmarkReport.make(
                results: results,
                jsonReportURL: jsonURL,
                markdownReportURL: markdownURL,
                localModelSelectionRawValue: runModelSelection.rawValue,
                localModelDisplayName: runModelSelection.displayName,
                modelSource: selectedModelSource
            )
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
            let semantic = result.semanticPassed ? "pass" : result.semanticFailures.joined(separator: "; ").truncated(to: 120)
            let contract = result.runtimeMetrics.contractFailureCount == 0 ? "pass" : "\(result.runtimeMetrics.contractFailureCount)"
            return "| \(result.taskID) | \(result.status) | \(result.semanticPassed ? "yes" : "no") | \(semantic) | \(contract) | \(format(result.f1)) | \(Int(result.activeRuntimeMilliseconds))ms | \(Int(result.wallClockMilliseconds))ms | \(Int(result.systemPermissionWaitMilliseconds))ms | \(result.toolAttemptCount) | \(result.toolExecutionCount) | \(result.toolReplayCount) | \(result.actualTools.joined(separator: ", ")) | \(result.modelMetrics.count) |"
        }.joined(separator: "\n")
        return """
        # Lumina In-App Benchmark Report

        Generated: \(report.generatedAt)

        ## Summary
        - Local model selection: \(report.localModelDisplayName ?? "unknown") (\(report.localModelSelectionRawValue ?? "unknown"))
        - Runtime model source: \(report.modelSource ?? "unknown")
        - Tasks: \(report.completedCount)/\(report.taskCount)
        - Succeeded: \(report.succeededCount)
        - Failed: \(report.failedCount)
        - Pass@1: \(report.passAt1Count)/\(report.completedCount) (\(format(report.passAt1Rate)))
        - Tool execution@1: \(report.toolExecutionAt1Count)/\(toolRequiredTaskCount(report)) (\(format(report.toolExecutionAt1Rate)))
        - Semantic pass: \(report.semanticPassedCount)/\(report.completedCount) (\(format(report.semanticPassRate)))
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
        - Tool attempts / executions / replays: \(report.results.reduce(0) { $0 + $1.toolAttemptCount }) / \(report.results.reduce(0) { $0 + $1.toolExecutionCount }) / \(report.results.reduce(0) { $0 + $1.toolReplayCount })

        ## Runtime Contract & Observability
        - Contract failure count/rate: \(report.runtimeContractFailureCount) / \(format(report.runtimeContractFailureRate))
        - Normalization failures: \(report.normalizationFailureCount)
        - Schema validation failures: \(report.schemaValidationFailureCount)
        - Model-owned observation rejects: \(report.modelOwnedObservationRejectCount)
        - Unknown tool rejects: \(report.unknownToolRejectCount)
        - Retry / fallback count: \(report.retryCount) / \(report.fallbackCount)
        - Runtime observations / results / hook events: \(report.runtimeObservationCount) / \(report.resultGeneratedCount) / \(report.hookEventCount)
        - Tool failures: \(report.toolFailureCount)
        - Deferred tool schema tokens saved estimate: \(report.schemaTokensSavedEstimate)
        - Tool discovery hit rate: \(format(report.toolDiscoveryHitRate))
        - Deferred unknown tool rate: \(format(report.deferredUnknownToolRate))
        - Tool loading search / loaded / failed: \(report.toolLoadingSearchCount) / \(report.toolLoadingLoadedCount) / \(report.toolLoadingLoadFailedCount)
        - Context loading catalog / search / loaded / failed: \(report.contextLoadingCatalogEmittedCount) / \(report.contextLoadingSearchCount) / \(report.contextLoadingLoadedCount + report.contextLoadingRangeLoadedCount) / \(report.contextLoadingLoadFailedCount)
        - Context loading hit rate: \(format(report.contextLoadingHitRate))
        - Context cache hits / token estimate: \(report.contextLoadingCacheHitCount) / \(report.contextLoadingTokensEstimate)

        ## Model Inference
        - Model invocations: \(report.modelInvocationCount)
        - Local / remote invocations: \(report.localModelInvocationCount) / \(report.remoteModelInvocationCount)
        - TTFT p50/p95: \(optionalMilliseconds(report.modelTTFTP50Milliseconds)) / \(optionalMilliseconds(report.modelTTFTP95Milliseconds))
        - Decode tokens/s p50/p95: \(optionalNumber(report.modelTokensPerSecondP50)) / \(optionalNumber(report.modelTokensPerSecondP95))
        - Prompt tokens p95: \(optionalNumber(report.modelPromptTokensP95))
        - Output tokens p95: \(optionalNumber(report.modelOutputTokensP95))

        ## Tasks
        | Task | Status | Semantic | Semantic detail | Contract | Tool F1 | Active latency | Wall clock | Permission wait | Attempts | Executions | Replays | Executed tools | Model calls |
        | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
        \(rows)
        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func toolRequiredTaskCount(_ report: LuminaBenchmarkReport) -> Int {
        report.results.filter { !$0.expectedTools.isEmpty }.count
    }

    private func optionalMilliseconds(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int(value))ms"
    }

    private func optionalNumber(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return String(format: "%.2f", value)
    }

    private func prepareBenchmarkFixtures(traceLogger: LuminaBenchmarkTraceLogger) async {
        do {
            try await createIsolatedCalendarFixtures()
            try createIsolatedFileFixtures()
            await traceLogger.record("benchmark_fixtures_ready", fields: [
                "calendar": "LuminaTest 项目同步",
                "reminder": "LuminaTest 带伞",
                "mode": "isolated"
            ])
        } catch {
            await traceLogger.record("benchmark_fixtures_failed", fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private func createIsolatedCalendarFixtures() async throws {
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date().addingTimeInterval(86_400)
        let end = start.addingTimeInterval(1_800)
        _ = await services.evaluationCalendarStore.addEvent(LuminaCalendarEvent(
            title: "LuminaTest 项目同步",
            startDate: start,
            endDate: end,
            notes: "Lumina benchmark fixture"
        ))
        let due = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        _ = await services.evaluationCalendarStore.addReminder(LuminaReminderItem(
            title: "LuminaTest 带伞",
            notes: "Lumina benchmark fixture",
            dueDate: due
        ))
    }

    private func createIsolatedFileFixtures() throws {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let notes = documents.appendingPathComponent("Lumina Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "# LuminaTest Daily\n\n今天完成 benchmark fixture 验证。\n".write(
            to: notes.appendingPathComponent("LuminaTest-daily.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# LuminaTest\n\n这是一篇用于 benchmark 的本地笔记。\n".write(
            to: notes.appendingPathComponent("LuminaTest.md"),
            atomically: true,
            encoding: .utf8
        )
        try "# LuminaTest Report\n\nBenchmark covers XML ReAct, tool choice, and local runtime execution.\n".write(
            to: documents.appendingPathComponent("LuminaTest-report.md"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private enum LuminaBenchmarkSemanticEvaluator {
    @MainActor
    static func evaluate(task: LuminaBenchmarkTask, result: LuminaAgentRunResult, services: AgentAppServices) async -> [String] {
        var failures: [String] = []
        guard result.status != .cancelled else {
            failures.append("runtime cancelled")
            return failures
        }
        let evidence = finalEvidence(from: result)
        let text = task.text
        let events = await services.evaluationCalendarStore.allEvents()
        let reminders = await services.evaluationCalendarStore.allReminders()
        let ledgerTransactions = await services.ledgerStore.allTransactions()
        let subscriptions = await services.subscriptionStore.allSubscriptions()
        let documents = documentsDirectory()
        let executedResults = result.toolResults.filter { $0.output["replayed"]?.boolValue != true }
        failures.append(contentsOf: validateExpectedTools(
            expectedTools: task.expectedTools,
            taskText: text,
            result: result,
            toolResults: executedResults
        ))
        if finalAnswerRejectsCompletion(evidence) {
            failures.append("final answer indicates task was not completed")
        } else if !outcomeSatisfied(
            taskText: text,
            evidence: evidence,
            events: events,
            reminders: reminders,
            ledgerTransactions: ledgerTransactions,
            subscriptions: subscriptions,
            documentsDirectory: documents
        ) {
            failures.append("final outcome did not match benchmark expectation")
        }
        return failures
    }

    private static func finalEvidence(from result: LuminaAgentRunResult) -> String {
        result.plan.summary
    }

    private static func outcomeSatisfied(
        taskText text: String,
        evidence: String,
        events: [LuminaCalendarEvent],
        reminders: [LuminaReminderItem],
        ledgerTransactions: [LuminaLedgerTransaction],
        subscriptions: [LuminaContentSubscription],
        documentsDirectory: URL
    ) -> Bool {
        if text.contains("现在几点") || text.contains("当前时间") {
            return containsAny(evidence, ["时间", "点", ":", "T"])
        }
        if text.contains("今天下午有没有会议") {
            return containsAny(evidence, ["没有", "会议", "空", "LuminaTest", "项目同步"])
        }
        if text.contains("创建明天上午 7 点的日程") {
            return events.contains { event in
                containsAll(event.title, ["LuminaTest", "上厕所"]) &&
                    hourMinute(event.startDate) == (7, 0)
            }
        }
        if text.contains("日程改成 7 点半") {
            return events.contains { event in
                event.title.localizedCaseInsensitiveContains("LuminaTest") &&
                    hourMinute(event.startDate) == (7, 30)
            }
        }
        if text.contains("删除那个标题是 LuminaTest 项目同步的日程") {
            return !events.contains { $0.title == "LuminaTest 项目同步" }
        }
        if text.contains("明天下午三点到四点有空吗") {
            return containsAny(evidence, ["有空", "可用", "空闲", "没有冲突", "available"])
        }
        if text.contains("今天还有哪些提醒") {
            return containsAny(evidence, ["LuminaTest", "带伞", "提醒"])
        }
        if text.contains("明天早上 8 点提醒我 LuminaTest 带伞") {
            return reminders.contains { reminder in
                containsAll(reminder.title, ["LuminaTest", "带伞"]) &&
                    reminder.dueDate.map { hourMinute($0) == (8, 0) } == true
            }
        }
        if text.contains("带伞提醒改到明早 8 点半") {
            return reminders.contains { reminder in
                reminder.title.localizedCaseInsensitiveContains("带伞") &&
                    reminder.dueDate.map { hourMinute($0) == (8, 30) } == true
            }
        }
        if text.contains("带伞这个提醒标记完成") {
            return reminders.contains { $0.title.localizedCaseInsensitiveContains("带伞") && $0.isCompleted }
        }
        if text.contains("删除 LuminaTest 带伞这个提醒") {
            return !reminders.contains { $0.title.localizedCaseInsensitiveContains("LuminaTest 带伞") }
        }
        if text.contains("联系人") {
            if text.contains("加一个邮箱") { return containsAny(evidence, ["test@example.com", "已更新"]) }
            if text.contains("创建联系人") { return containsAll(evidence, ["LuminaTest", "10086"]) || containsAny(evidence, ["已创建"]) }
            if text.contains("打开联系人") { return containsAny(evidence, ["详情", "已准备打开", "test"]) }
            return containsAny(evidence, ["10086", "test@example.com", "LuminaTest", "test"])
        }
        if text.contains("咖啡店") { return containsAny(evidence, ["咖啡", "coffee"]) }
        if text.contains("Apple Park") { return containsAny(evidence, ["Apple Park", "apple", "路线", "导航"]) }
        if text.contains("我现在在哪") { return containsAny(evidence, ["位置", "location", "纬", "经"]) }
        if text.contains("半小时后通知我 LuminaTest 喝水") {
            return containsAll(evidence, ["LuminaTest", "喝水"]) || containsAny(evidence, ["本地通知已安排"])
        }
        if text.contains("读取剪贴板") {
            return containsAny(evidence, ["LuminaTest benchmark clipboard content", "LuminaTest", "剪贴板"])
        }
        if text.contains("复制到剪贴板") {
            return containsAny(evidence, ["LuminaTest benchmark", "已写入剪贴板"])
        }
        if text.contains("保存成 Markdown 笔记") || text.contains("保存成 Markdown") {
            return noteFiles(in: documentsDirectory).contains { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { $0.localizedCaseInsensitiveContains("LuminaTest") } == true
            } || containsAny(evidence, ["已保存", "Lumina Notes"])
        }
        if text.contains("列出我保存过的 Lumina 笔记") || text.contains("列出本地 Markdown 笔记") {
            return containsAny(evidence, ["LuminaTest", "daily", ".md", "笔记"])
        }
        if text.contains("读取 LuminaTest-daily.md") {
            return containsAny(evidence, ["今天完成 benchmark", "LuminaTest Daily", "fixture"])
        }
        if text.contains("追加今天的进展") {
            return noteText(named: "LuminaTest-daily.md", in: documentsDirectory).localizedCaseInsensitiveContains("进展") ||
                containsAny(evidence, ["已更新", "已追加"])
        }
        if text.contains("删除 LuminaTest-daily.md") {
            return !FileManager.default.fileExists(atPath: notesDirectory(in: documentsDirectory).appendingPathComponent("LuminaTest-daily.md").path)
        }
        if text.contains("分享刚才保存") { return containsAny(evidence, ["分享内容已准备", "已准备"]) }
        if text.contains("系统设置") { return containsAny(evidence, ["设置", "settings", "已打开"]) }
        if text.contains("电量") || text.contains("网络") || text.contains("存储") {
            return containsAny(evidence, ["电量", "网络", "存储", "battery", "network", "storage", "低电量"])
        }
        if text.contains("改写成 3 条检查项") || text.contains("整理成待办列表") || text.contains("整理成一句摘要") {
            return evidence.trimmingCharacters(in: .whitespacesAndNewlines).count > 8
        }
        if text.contains("记录 42 元 LuminaTest 咖啡支出") {
            return ledgerTransactions.contains { transaction in
                containsAll(transaction.memo, ["LuminaTest", "咖啡"]) &&
                    transaction.amount.map { NSDecimalNumber(decimal: $0).doubleValue == 42 } == true
            }
        }
        if text.contains("查最近的 LuminaTest 咖啡支出") || text.contains("汇总这个月 LuminaTest 咖啡") {
            return containsAny(evidence, ["LuminaTest", "咖啡", "42", "40"])
        }
        if text.contains("咖啡账目金额改成 40 元") {
            return ledgerTransactions.contains { transaction in
                transaction.memo.localizedCaseInsensitiveContains("咖啡") &&
                    transaction.amount.map { NSDecimalNumber(decimal: $0).doubleValue == 40 } == true
            }
        }
        if text.contains("删除那条 LuminaTest 咖啡账目") {
            return !ledgerTransactions.contains { containsAll($0.memo, ["LuminaTest", "咖啡"]) }
        }
        if text.contains("订阅 https://example.com/feed.xml") {
            return subscriptions.contains { $0.source.localizedCaseInsensitiveContains("example.com/feed.xml") }
        }
        if text.contains("列出我的订阅源") || text.contains("列出我的 RSS 订阅源") {
            return containsAny(evidence, ["example.com", "订阅", "RSS"])
        }
        if text.contains("删除 LuminaTest example 这个订阅源") {
            return !subscriptions.contains { $0.source.localizedCaseInsensitiveContains("LuminaTest") || $0.source.localizedCaseInsensitiveContains("example") }
        }
        if text.contains("https://example.com") {
            return containsAny(evidence, ["Example Domain", "example.com", "LuminaTest web"])
        }
        if text.contains("LuminaTest-report.md") {
            return containsAny(evidence, ["LuminaTest report", "benchmark covers", "runtime execution"])
        }
        if text.contains("图片") {
            return containsAny(evidence, ["LuminaTest image", "640", "360", "12345", "文字"])
        }
        if text.contains("12*(8+3)-5") {
            return evidence.contains("127")
        }
        return evidence.trimmingCharacters(in: .whitespacesAndNewlines).count > 8
    }

    private static func validateExpectedTools(
        expectedTools: [String],
        taskText: String,
        result: LuminaAgentRunResult,
        toolResults: [LuminaToolResult]
    ) -> [String] {
        var failures: [String] = []
        for toolName in expectedTools {
            guard hasSucceededTool(toolName, in: result) else {
                failures.append("\(toolName) did not succeed")
                continue
            }
            failures.append(contentsOf: validate(
                toolName: toolName,
                taskText: taskText,
                result: result,
                toolResults: toolResults
            ))
        }
        return failures
    }

    private static func hasSucceededTool(_ toolName: String, in result: LuminaAgentRunResult) -> Bool {
        result.toolResults.contains { toolResult in
            toolResult.toolName == toolName &&
                toolResult.status == .succeeded &&
                toolResult.output["replayed"]?.boolValue != true
        }
    }

    private static func finalAnswerRejectsCompletion(_ evidence: String) -> Bool {
        let failureMarkers = [
            "无法完成",
            "无法继续",
            "执行预算",
            "没有生成result",
            "没有生成 result",
            "不能重复",
            "缺少",
            "未找到",
            "did not return",
            "空转保护",
            "Agent 已停止"
        ]
        return failureMarkers.contains { evidence.localizedCaseInsensitiveContains($0) }
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
    }

    private static func notesDirectory(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true)
    }

    private static func noteFiles(in documentsDirectory: URL) -> [URL] {
        let notes = notesDirectory(in: documentsDirectory)
        return (try? FileManager.default.contentsOfDirectory(at: notes, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension.lowercased() == "md" } ?? []
    }

    private static func noteText(named filename: String, in documentsDirectory: URL) -> String {
        (try? String(contentsOf: notesDirectory(in: documentsDirectory).appendingPathComponent(filename), encoding: .utf8)) ?? ""
    }

    private static func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.localizedCaseInsensitiveContains($0) }
    }

    private static func containsAll(_ text: String, _ needles: [String]) -> Bool {
        needles.allSatisfy { text.localizedCaseInsensitiveContains($0) }
    }

    private static func hourMinute(_ date: Date) -> (Int, Int) {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? -1, components.minute ?? -1)
    }

    private static func validate(
        toolName: String,
        taskText: String,
        result: LuminaAgentRunResult,
        toolResults: [LuminaToolResult]
    ) -> [String] {
        let calls = result.plan.toolCalls.filter { $0.toolName == toolName }
        guard !calls.isEmpty else { return ["\(toolName) had no recorded call arguments"] }
        let lastOutput = toolResults.last { $0.toolName == toolName }?.output ?? [:]
        let lastCall = calls.last
        var failures: [String] = []

        func requireArgument(_ key: String, contains needle: String, label: String? = nil) {
            guard let value = lastCall?.arguments.string(key), value.localizedCaseInsensitiveContains(needle) else {
                failures.append("\(toolName).\(key) should contain \(label ?? needle)")
                return
            }
        }

        func requireAnyArgument(_ key: String, contains needles: [String]) {
            guard let value = lastCall?.arguments.string(key),
                  needles.contains(where: { value.localizedCaseInsensitiveContains($0) }) else {
                failures.append("\(toolName).\(key) should contain one of \(needles.joined(separator: ","))")
                return
            }
        }

        func requireOutput(_ key: String, contains needle: String) {
            guard valueText(lastOutput[key]).localizedCaseInsensitiveContains(needle) else {
                failures.append("\(toolName) output.\(key) should contain \(needle)")
                return
            }
        }

        func requireArgumentOrOutput(_ key: String, contains needle: String, label: String? = nil) {
            let argument = lastCall?.arguments.string(key) ?? ""
            let output = lastOutput.values.map(valueText).joined(separator: " ")
            guard argument.localizedCaseInsensitiveContains(needle) ||
                    output.localizedCaseInsensitiveContains(needle) else {
                failures.append("\(toolName).\(key) or output should contain \(label ?? needle)")
                return
            }
        }

        func requireDateArgument(_ key: String, hour: Int? = nil, minute: Int? = nil, future: Bool = false) {
            guard let raw = lastCall?.arguments.string(key), let date = parseDate(raw) else {
                failures.append("\(toolName).\(key) should be a valid ISO-8601 date")
                return
            }
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            if let hour, components.hour != hour {
                failures.append("\(toolName).\(key) hour should be \(hour)")
            }
            if let minute, components.minute != minute {
                failures.append("\(toolName).\(key) minute should be \(minute)")
            }
            if future && date < Date().addingTimeInterval(-300) {
                failures.append("\(toolName).\(key) should be in the future")
            }
        }

        switch toolName {
        case "device.current_time", "device.power_status", "network.status", "storage.status", "location.current":
            break
        case "calendar.search":
            if taskText.contains("会议") {
                requireArgument("query", contains: "会议")
            } else if taskText.contains("LuminaTest") {
                requireArgumentOrOutput("query", contains: "LuminaTest")
            }
        case "calendar.create":
            requireArgument("title", contains: "LuminaTest")
            if taskText.contains("上厕所") { requireArgument("title", contains: "上厕所") }
            requireDateArgument("startDateISO", hour: 7, minute: 0, future: true)
        case "calendar.update":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
            requireDateArgument("startDateISO", hour: 7, minute: 30, future: true)
        case "calendar.delete":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
        case "calendar.availability":
            requireDateArgument("startDateISO", hour: 15, minute: 0, future: true)
            requireDateArgument("endDateISO", hour: 16, minute: 0, future: true)
        case "reminder.search":
            if taskText.contains("带伞") {
                requireArgument("query", contains: "带伞")
            }
        case "reminder.create":
            requireArgument("title", contains: "LuminaTest")
            requireArgument("title", contains: "带伞")
            requireDateArgument("dueDateISO", hour: 8, minute: 0, future: true)
        case "reminder.update":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
            requireDateArgument("dueDateISO", hour: 8, minute: 30, future: true)
        case "reminder.complete", "reminder.delete":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
        case "contacts.search", "contacts.open":
            requireAnyArgument("query", contains: ["test", "LuminaTest"])
        case "contacts.create":
            requireArgument("name", contains: "LuminaTest")
            requireArgument("name", contains: "test")
            requireArgument("phone", contains: "10086")
        case "contacts.update":
            if lastCall?.arguments.string("id") == nil {
                requireArgument("name", contains: "LuminaTest")
            }
            requireArgument("email", contains: "test@example.com")
        case "message.compose":
            requireArgument("recipient", contains: "test")
            requireArgument("body", contains: "十分钟后到")
        case "email.compose":
            requireArgument("recipient", contains: "test")
            requireArgument("subject", contains: "LuminaTest")
            requireArgument("subject", contains: "周报")
        case "maps.search":
            requireAnyArgument("query", contains: ["咖啡", "coffee"])
        case "maps.route":
            requireAnyArgument("destination", contains: ["Apple Park", "apple"])
        case "notification.schedule":
            requireAnyArgument("title", contains: ["LuminaTest", "喝水"])
            requireAnyArgument("body", contains: ["LuminaTest", "喝水"])
            requireScheduleArgument(taskText: taskText, call: lastCall, toolName: toolName, failures: &failures)
        case "clipboard.write":
            requireArgument("text", contains: "LuminaTest")
            requireArgument("text", contains: "benchmark")
        case "file.save_note":
            if taskText.contains("LuminaTest") {
                requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest", toolName: toolName, failures: &failures)
            }
        case "file.read_note", "file.update_note", "file.delete_note":
            requireAnyArgument("filename", contains: ["LuminaTest-daily.md", "LuminaTest-daily"])
        case "ledger.record":
            requireNumberArgument("amount", expected: 42, toolName: toolName, call: lastCall, failures: &failures)
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest", toolName: toolName, failures: &failures)
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "咖啡", toolName: toolName, failures: &failures)
        case "ledger.search", "ledger.summary":
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest", toolName: toolName, failures: &failures)
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "咖啡", toolName: toolName, failures: &failures)
        case "ledger.update":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
            requireNumberArgument("amount", expected: 40, toolName: toolName, call: lastCall, failures: &failures)
        case "ledger.delete":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
        case "subscription.add":
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "https://example.com/feed.xml", toolName: toolName, failures: &failures)
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest", toolName: toolName, failures: &failures)
        case "subscription.remove":
            requireNonEmptyID(lastCall, toolName: toolName, failures: &failures)
        case "webpage.fetch_text":
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "https://example.com", toolName: toolName, failures: &failures)
        case "document.read_text":
            requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest-report.md", toolName: toolName, failures: &failures)
        case "calculator.evaluate":
            requireAnyArgument("expression", contains: ["12*(8+3)-5", "12 * (8 + 3) - 5"])
            if !valueText(lastOutput["result"]).contains("127") && !valueText(lastOutput["summary"]).contains("127") {
                failures.append("calculator.evaluate output should contain result 127")
            }
        case "text.transform":
            if taskText.contains("LuminaTest") {
                requireAnyText(in: lastCall?.arguments ?? [:], contains: "LuminaTest", toolName: toolName, failures: &failures)
            }
        default:
            break
        }
        if toolName != "share.prepare" && toolName != "app.open_settings" && toolName != "image.extract_text" && toolName != "image.describe_metadata",
           let toolResult = toolResults.last(where: { $0.toolName == toolName }),
           toolResult.status == .succeeded,
           lastOutput.isEmpty {
            failures.append("\(toolName) returned empty output")
        }
        return failures
    }

    private static func requireNonEmptyID(_ call: LuminaToolCall?, toolName: String, failures: inout [String]) {
        guard let id = call?.arguments.string("id"), !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            failures.append("\(toolName).id is required for semantic correctness")
            return
        }
    }

    private static func requireScheduleArgument(
        taskText: String,
        call: LuminaToolCall?,
        toolName: String,
        failures: inout [String]
    ) {
        if let raw = call?.arguments.string("dateISO"), let date = parseDate(raw) {
            if date < Date().addingTimeInterval(-300) {
                failures.append("\(toolName).dateISO should be in the future")
            }
            return
        }
        if let seconds = call?.arguments.number("timeIntervalSeconds") {
            if seconds <= 0 {
                failures.append("\(toolName).timeIntervalSeconds should be positive")
            }
            if taskText.contains("半小时") && !(1_500...2_100).contains(seconds) {
                failures.append("\(toolName).timeIntervalSeconds should be about 1800 for 半小时")
            }
            return
        }
        failures.append("\(toolName) should provide future dateISO or positive timeIntervalSeconds")
    }

    private static func requireAnyArgument(_ key: String, contains needles: [String], toolName: String? = nil, call: LuminaToolCall? = nil, failures: inout [String]) {
        guard let value = call?.arguments.string(key),
              needles.contains(where: { value.localizedCaseInsensitiveContains($0) }) else {
            failures.append("\(toolName.map { "\($0)." } ?? "")\(key) should contain one of \(needles.joined(separator: ","))")
            return
        }
    }

    private static func requireNumberArgument(_ key: String, expected: Double, toolName: String, call: LuminaToolCall?, failures: inout [String]) {
        guard let value = call?.arguments.number(key), abs(value - expected) < 0.001 else {
            failures.append("\(toolName).\(key) should be \(expected)")
            return
        }
    }

    private static func requireAnyText(in arguments: [String: LuminaJSONValue], contains needle: String, toolName: String, failures: inout [String]) {
        let text = arguments.values.map(valueText).joined(separator: " ")
        guard text.localizedCaseInsensitiveContains(needle) else {
            failures.append("\(toolName) arguments should contain \(needle)")
            return
        }
    }

    private static func parseDate(_ raw: String) -> Date? {
        ISO8601DateFormatter().date(from: raw)
    }

    private static func valueText(_ value: LuminaJSONValue?) -> String {
        guard let value else { return "" }
        switch value {
        case let .string(string):
            return string
        case let .number(number):
            return String(number)
        case let .bool(bool):
            return String(bool)
        case let .object(object):
            return object.values.map(valueText).joined(separator: " ")
        case let .array(array):
            return array.map(valueText).joined(separator: " ")
        case .null:
            return ""
        }
    }
}

@MainActor
enum LuminaBenchmarkPermissionWarmup {
    static func requestAllNeededPermissions() async {
        // Evaluation runtime uses isolated benchmark tools, so warmup should not
        // trigger real Calendar, Contacts, Notifications, or Location prompts.
    }

    private static func requestCalendarAccess() async {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        _ = try? await store.requestFullAccessToEvents()
    }

    private static func requestReminderAccess() async {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .notDetermined else { return }
        _ = try? await store.requestFullAccessToReminders()
    }

    private static func requestContactsAccess() async {
        let store = CNContactStore()
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        _ = try? await store.requestAccess(for: .contacts)
    }

    private static func requestNotificationAccess() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private static func requestLocationAccess() async {
        // Do not resolve a real location during benchmark warmup. On Mac Catalyst
        // CLLocationManager.requestLocation() can wait indefinitely when location
        // services are unavailable, which blocks the benchmark before task 1.
        guard CLLocationManager.locationServicesEnabled() else { return }
        let manager = CLLocationManager()
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }
}
