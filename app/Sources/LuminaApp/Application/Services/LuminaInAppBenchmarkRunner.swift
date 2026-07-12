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
        let runID = UUID()
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
        var results: [LuminaBenchmarkTaskResult] = []
        for (taskIndex, task) in tasks.enumerated() {
            if Task.isCancelled { break }
            let taskEnvironment = LuminaBenchmarkTaskEnvironment(runID: runID, taskID: task.id, rootDirectory: reportDirectory)
            do {
                try await taskEnvironment.prepare(for: task)
            } catch {
                await traceLogger.record("benchmark_task_fixture_failed", fields: [
                    "taskID": task.id,
                    "error": error.localizedDescription
                ])
            }
            await traceLogger.record("task_started", fields: [
                "taskID": task.id,
                "taskIndex": "\(taskIndex + 1)",
                "text": task.text,
                "category": task.category,
                "expectedTools": task.expectedTools.joined(separator: ","),
                "documentsDirectory": taskEnvironment.documentsDirectory.path
            ])
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: task.expectedTools.last))
            services.beginSession()
            let metricsMark = services.modelMetrics.mark()
            let (result, observedTimings) = await runSingleTask(task, environment: taskEnvironment, completed: results.count, total: tasks.count, traceLogger: traceLogger, progress: progress)
            let modelMetrics = services.modelMetrics.metrics(after: metricsMark)
            let observedToolResults = benchmarkToolResults(from: result)
                .filter { !Self.isInternalRuntimeTool($0.toolName) }
            let toolAttempts = observedToolResults.map(\.toolName)
            let toolReplays = observedToolResults.filter { $0.output["replayed"]?.boolValue == true }.map(\.toolName)
            let executedResults = observedToolResults.filter { $0.output["replayed"]?.boolValue != true }
            let actualTools = executedResults.map(\.toolName)
            let successfulTools = executedResults.filter { $0.status == .succeeded }.map(\.toolName)
            let failedTools = executedResults.filter { $0.status != .succeeded }.map(\.toolName)
            let expectedSet = Set(task.expectedTools)
            let actualSet = Set(successfulTools)
            let missingTools = expectedSet.subtracting(actualSet).sorted()
            let unexpectedTools = Set(actualTools).subtracting(expectedSet).sorted()
            let terminationReason = result.reactTrace?.terminationReason
            let outcomeFailures = await LuminaBenchmarkOutcomeEvaluator.evaluate(
                task: task,
                result: result,
                environment: taskEnvironment,
                toolResults: observedToolResults
            )
            let semanticFailures = outcomeFailures
            let runtimeDiagnostics = Self.runtimeDiagnostics(status: result.status.rawValue, terminationReason: terminationReason)
            let outcomeSummary = outcomeFailures.joined(separator: "; ")
            let toolDiagnostics = [
                missingTools.isEmpty ? nil : "missing=\(missingTools.joined(separator: ","))",
                unexpectedTools.isEmpty ? nil : "unexpected=\(unexpectedTools.joined(separator: ","))",
                failedTools.isEmpty ? nil : "failed=\(failedTools.joined(separator: ","))",
                toolReplays.isEmpty ? nil : "replayed=\(toolReplays.joined(separator: ","))"
            ].compactMap { $0 }.joined(separator: "; ")
            let failure = [
                runtimeDiagnostics.isEmpty ? nil : runtimeDiagnostics,
                outcomeSummary.isEmpty ? nil : outcomeSummary,
                toolDiagnostics.isEmpty ? nil : toolDiagnostics
            ]
                .compactMap { $0 }
                .joined(separator: "\n")
            let taskResult = LuminaBenchmarkTaskResult(
                task: task,
                toolAttempts: toolAttempts,
                actualTools: actualTools,
                toolReplays: toolReplays,
                successfulTools: successfulTools,
                failedTools: failedTools,
                outcomeFailures: outcomeFailures,
                runtimeStatus: result.status.rawValue,
                terminationReason: terminationReason,
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
                "terminationReason": terminationReason ?? "",
                "status": taskResult.status,
                "outcomePassed": "\(taskResult.outcomePassed)",
                "strictToolPassed": "\(taskResult.strictToolPassed)",
                "orderedToolMatch": "\(taskResult.orderedToolMatch)",
                "expectedToolsEffective": task.expectedTools.joined(separator: ","),
                "missingTools": missingTools.joined(separator: ","),
                "unexpectedTools": unexpectedTools.joined(separator: ","),
                "failedTools": failedTools.joined(separator: ","),
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
            taskEnvironment.cleanup(keepArtifacts: taskResult.status != "succeeded")
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

    private static func runtimeDiagnostics(status: String, terminationReason: String?) -> String {
        var diagnostics: [String] = []
        if status != "succeeded" && status != "partiallySucceeded" {
            diagnostics.append("runtime status \(status)")
        }
        if let terminationReason,
           runtimeFailureTerminationReasons.contains(terminationReason) {
            diagnostics.append("runtime termination \(terminationReason)")
        }
        return diagnostics.joined(separator: "; ")
    }

    private static func isInternalRuntimeTool(_ toolName: String) -> Bool {
        toolName.hasPrefix("runtime.")
    }

    private static let runtimeFailureTerminationReasons: Set<String> = [
        "cannot-complete",
        "budget",
        "iteration-budget",
        "reasoning-budget",
        "tool-budget",
        "replay-loop",
        "model-empty-output",
        "invalid-model-output",
        "cancelled",
        "stopped"
    ]

    private func runSingleTask(
        _ task: LuminaBenchmarkTask,
        environment: LuminaBenchmarkTaskEnvironment,
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
        for await event in services.runEvaluationStream(task: task, environment: environment) {
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
            if case let .multiActionProposed(calls) = event {
                let names = calls.map(\.toolName).joined(separator: " -> ")
                latestActivity = names
                progress(LuminaBenchmarkSnapshot(
                    state: .running,
                    currentTask: "\(task.text) · multi-action \(names)",
                    completed: completed,
                    total: total,
                    latestTool: names
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
        case let .multiActionProposed(calls):
            fields["toolNames"] = calls.map(\.toolName).joined(separator: ",")
            fields["callCount"] = "\(calls.count)"
            await traceLogger.record("multi_action_proposed", fields: fields)
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
        selection.resolvedMiniCPMV46ModelURL()
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
            let outcome = result.outcomePassed ? "pass" : result.outcomeFailures.joined(separator: "; ").truncated(to: 120)
            let contract = Self.contractSummary(result.runtimeMetrics)
            return "| \(result.taskID) | \(result.status) | \(result.outcomePassed ? "yes" : "no") | \(result.strictToolPassed ? "yes" : "no") | \(result.runtimeStatus) | \(result.terminationReason ?? "") | \(outcome) | \(contract) | \(format(result.f1)) | \(Int(result.activeRuntimeMilliseconds))ms | \(Int(result.wallClockMilliseconds))ms | \(result.toolAttemptCount) | \(result.toolExecutionCount) | \(result.toolReplayCount) | \(result.successfulTools.joined(separator: ", ")) | \(result.missingTools.joined(separator: ", ")) | \(result.unexpectedTools.joined(separator: ", ")) | \(result.failedTools.joined(separator: ", ")) | \(result.modelMetrics.count) |"
        }.joined(separator: "\n")
        return """
        # Lumina In-App Benchmark Report

        Generated: \(report.generatedAt)

        ## Summary
        - Local model selection: \(report.localModelDisplayName ?? "unknown") (\(report.localModelSelectionRawValue ?? "unknown"))
        - Runtime model source: \(report.modelSource ?? "unknown")
        - Tasks: \(report.completedCount)/\(report.taskCount)
        - Outcome succeeded: \(report.outcomePassedCount)/\(report.completedCount) (\(format(report.outcomePassRate)))
        - Succeeded: \(report.succeededCount)
        - Failed: \(report.failedCount)
        - Pass@1: \(report.passAt1Count)/\(report.completedCount) (\(format(report.passAt1Rate))) single-sample outcome pass
        - Strict tool pass: \(report.strictToolPassCount)/\(report.completedCount) (\(format(report.strictToolPassRate))) ordered expected tools with no unexpected/failed/replayed calls
        - Ordered tool match: \(report.orderedToolMatchCount)/\(report.completedCount) (\(format(report.orderedToolMatchRate)))
        - Tool execution@1: \(report.toolExecutionAt1Count)/\(toolRequiredTaskCount(report)) (\(format(report.toolExecutionAt1Rate)))
        - Semantic pass: \(report.semanticPassedCount)/\(report.completedCount) (\(format(report.semanticPassRate)))
        - Exact tool match: \(format(report.exactToolMatch))
        - Micro precision: \(format(report.microPrecision))
        - Micro recall: \(format(report.microRecall))
        - Micro F1: \(format(report.microF1))
        - Missing / unexpected / failed / replayed tools: \(report.missingToolCount) / \(report.unexpectedToolCount) / \(report.failedToolCount) / \(report.replayedToolCount)
        - Active runtime p50/p95: \(Int(report.latencyP50Milliseconds))ms / \(Int(report.latencyP95Milliseconds))ms
        - Wall-clock p95: \(Int(report.wallClockP95Milliseconds))ms
        - Confirmation wait p95: \(Int(report.confirmationWaitP95Milliseconds))ms
        - System permission wait p95: \(Int(report.systemPermissionWaitP95Milliseconds))ms
        - Step generation p95: \(Int(report.stepGenerationP95Milliseconds))ms
        - Tool p95: \(Int(report.toolP95Milliseconds))ms
        - Memory access disabled: \(report.memoryAccessDisabled)
        - Tool attempts / executions / replays: \(report.toolAttemptCount) / \(report.toolExecutionCount) / \(report.toolReplayCount)

        ## Runtime Contract & Observability
        - Contract failure count/rate: \(report.runtimeContractFailureCount) / \(format(report.runtimeContractFailureRate))
        - Normalization failures: \(report.normalizationFailureCount)
        - Schema validation failures: \(report.schemaValidationFailureCount)
        - Model-owned observation rejects: \(report.modelOwnedObservationRejectCount)
        - Unknown tool rejects: \(report.unknownToolRejectCount)
        - MiniCPM validated generations: \(report.modelGenerationValidatedCount)
        - MiniCPM special-token streams: \(report.modelStreamContainsSpecialTokensCount)
        - Host canonical steps: \(report.hostReturnedCanonicalStepCount)
        - Core special-token extracted steps: \(report.coreExtractedSpecialTokenStepCount)
        - Canonical tool/result steps: \(report.canonicalToolUseStepCount) / \(report.canonicalResultStepCount)
        - Legacy thought/tool_response schema observed: \(report.legacyOutputSchemaObservedCount)
        - Retry / fallback count: \(report.retryCount) / \(report.fallbackCount)
        - Runtime observations / results / hook events: \(report.runtimeObservationCount) / \(report.resultGeneratedCount) / \(report.hookEventCount)
        - Tool failures: \(report.toolFailureCount)
        - Multi-tool generations / calls: \(report.multiToolGenerationCount) / \(report.multiToolCallCount)
        - Multi-tool partial failures: \(report.multiToolPartialFailureCount)
        - Internal runtime calls ignored: \(report.internalToolIgnoredCount)
        - Side-effect batch stops: \(report.sideEffectBatchStopCount)
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
        | Task | Status | Outcome | Strict | Runtime | Termination | Outcome detail | Contract | Tool F1 | Active latency | Wall clock | Attempts | Executions | Replays | Successful tools | Missing | Unexpected | Failed tools | Model calls |
        | --- | --- | --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- | ---: |
        \(rows)
        """
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func toolRequiredTaskCount(_ report: LuminaBenchmarkReport) -> Int {
        report.results.filter { !$0.expectedTools.isEmpty }.count
    }

    private static func contractSummary(_ metrics: LuminaBenchmarkRuntimeMetrics) -> String {
        var parts: [String] = []
        if metrics.contractFailureCount == 0 {
            parts.append("pass")
        } else {
            parts.append("fail=\(metrics.contractFailureCount)")
        }
        if metrics.modelStreamContainsSpecialTokensCount > 0 {
            parts.append("special=\(metrics.modelStreamContainsSpecialTokensCount)")
        }
        if metrics.hostReturnedCanonicalStepCount > 0 {
            parts.append("canonical=\(metrics.hostReturnedCanonicalStepCount)")
        }
        if metrics.legacyOutputSchemaObservedCount > 0 {
            parts.append("legacy=\(metrics.legacyOutputSchemaObservedCount)")
        }
        return parts.joined(separator: ", ")
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

private enum LuminaBenchmarkOutcomeEvaluator {
    @MainActor
    static func evaluate(
        task: LuminaBenchmarkTask,
        result: LuminaAgentRunResult,
        environment: LuminaBenchmarkTaskEnvironment,
        toolResults: [LuminaToolResult]
    ) async -> [String] {
        var failures: [String] = []
        let evidence = finalEvidence(from: result)
        let text = task.text
        let events = await environment.calendarStore.allEvents()
        let reminders = await environment.calendarStore.allReminders()
        let ledgerTransactions = await environment.ledgerStore.allTransactions()
        let subscriptions = await environment.subscriptionStore.allSubscriptions()
        let documents = environment.documentsDirectory
        let executedResults = toolResults.filter { $0.output["replayed"]?.boolValue != true }
        let successfulResults = executedResults.filter { $0.status == .succeeded }
        let successfulToolNames = Set(successfulResults.map(\.toolName))
        let missingExpectedTools = task.expectedTools.filter { !successfulToolNames.contains($0) }
        if !missingExpectedTools.isEmpty {
            failures.append("expected tools did not succeed: \(missingExpectedTools.joined(separator: ","))")
        }
        let satisfied = outcomeSatisfied(
            taskText: text,
            evidence: evidence,
            events: events,
            reminders: reminders,
            ledgerTransactions: ledgerTransactions,
            subscriptions: subscriptions,
            documentsDirectory: documents,
            toolResults: successfulResults
        )
        if finalAnswerRejectsCompletion(evidence) && !satisfied {
            failures.append("final answer indicates task was not completed")
        }
        if !satisfied {
            failures.append("final outcome did not match benchmark expectation")
        }
        return failures
    }

    private static func finalEvidence(from result: LuminaAgentRunResult) -> String {
        result.plan.summary
    }

    private static func finalAnswerRejectsCompletion(_ evidence: String) -> Bool {
        let failureMarkers = [
            "无法完成",
            "无法继续",
            "执行预算",
            "没有生成最终回答",
            "不能重复",
            "缺少",
            "未找到",
            "did not return",
            "空转保护",
            "Agent 已停止"
        ]
        return failureMarkers.contains { evidence.localizedCaseInsensitiveContains($0) }
    }

    private static func outcomeSatisfied(
        taskText text: String,
        evidence: String,
        events: [LuminaCalendarEvent],
        reminders: [LuminaReminderItem],
        ledgerTransactions: [LuminaLedgerTransaction],
        subscriptions: [LuminaContentSubscription],
        documentsDirectory: URL,
        toolResults: [LuminaToolResult]
    ) -> Bool {
        func outputText(for toolName: String) -> String {
            toolResults
                .filter { $0.toolName == toolName }
                .flatMap { $0.output.values.map(valueText) + $0.content.compactMap(\.textForModelInput) }
                .joined(separator: " ")
        }
        func hasSuccessfulTool(_ toolName: String) -> Bool {
            toolResults.contains { $0.toolName == toolName && $0.status == .succeeded }
        }
        let observationText = toolResults
            .flatMap { $0.output.values.map(valueText) + $0.content.compactMap(\.textForModelInput) }
            .joined(separator: " ")
        func observationAndAnswerContain(_ needles: [String]) -> Bool {
            containsAny(observationText, needles) && containsAny(evidence, needles)
        }
        func toolOutputAndAnswerContain(_ toolName: String, _ needles: [String]) -> Bool {
            containsAny(outputText(for: toolName), needles) && containsAny(evidence, needles)
        }
        if (text.contains("现在几点") || text.contains("当前时间")) &&
            !containsAny(text, ["电量", "网络", "存储"]) {
            return hasSuccessfulTool("device.current_time") &&
                containsAny(outputText(for: "device.current_time"), ["iso", "Asia", "hour", ":"]) &&
                containsAny(evidence, [":", "点", "早", "午", "晚", "202"])
        }
        if text.contains("今天下午有没有会议") {
            return hasSuccessfulTool("calendar.search") && toolOutputAndAnswerContain("calendar.search", ["会议", "LuminaTest", "项目同步", "没有"])
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
            return hasSuccessfulTool("calendar.availability") &&
                containsAny(outputText(for: "calendar.availability"), ["busy", "false", "没有", "有空", "可用", "空闲", "没有冲突", "available"]) &&
                containsAny(evidence, ["没有", "有空", "可用", "空闲", "没有冲突", "available"])
        }
        if text.contains("今天还有哪些提醒") {
            return hasSuccessfulTool("reminder.search") && toolOutputAndAnswerContain("reminder.search", ["LuminaTest", "带伞", "提醒"])
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
            if text.contains("加一个邮箱") { return hasSuccessfulTool("contacts.update") && observationAndAnswerContain(["test@example.com", "已更新"]) }
            if text.contains("创建联系人") { return hasSuccessfulTool("contacts.create") && (containsAll(observationText + evidence, ["LuminaTest", "10086"]) || observationAndAnswerContain(["已创建"])) }
            if text.contains("打开联系人") { return hasSuccessfulTool("contacts.open") && observationAndAnswerContain(["详情", "已准备打开", "test"]) }
            return hasSuccessfulTool("contacts.search") && observationAndAnswerContain(["10086", "test@example.com", "LuminaTest", "test"])
        }
        if text.contains("咖啡店") { return hasSuccessfulTool("maps.search") && observationAndAnswerContain(["咖啡", "coffee"]) }
        if text.contains("Apple Park") { return hasSuccessfulTool("maps.route") && observationAndAnswerContain(["Apple Park", "apple", "路线", "导航"]) }
        if text.contains("我现在在哪") {
            return hasSuccessfulTool("location.current") &&
                containsAny(outputText(for: "location.current") + evidence, ["位置", "location", "纬", "经", "latitude", "longitude", "Apple Park"])
        }
        if text.contains("半小时后通知我 LuminaTest 喝水") {
            return hasSuccessfulTool("notification.schedule") && (containsAll(observationText + evidence, ["LuminaTest", "喝水"]) || observationAndAnswerContain(["本地通知已安排"]))
        }
        if text.contains("读取剪贴板") {
            return hasSuccessfulTool("clipboard.read") &&
                containsAny(outputText(for: "clipboard.read"), ["LuminaTest benchmark clipboard content", "LuminaTest", "剪贴板"])
        }
        if text.contains("复制到剪贴板") {
            return hasSuccessfulTool("clipboard.write") && observationAndAnswerContain(["LuminaTest benchmark", "已写入剪贴板"])
        }
        if text.contains("保存成 Markdown 笔记") || text.contains("保存成 Markdown") {
            return noteFiles(in: documentsDirectory).contains { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { $0.localizedCaseInsensitiveContains("LuminaTest") } == true
            } || containsAny(evidence, ["已保存", "Lumina Notes"])
        }
        if text.contains("列出我保存过的 Lumina 笔记") || text.contains("列出本地 Markdown 笔记") {
            return hasSuccessfulTool("file.list_notes") && observationAndAnswerContain(["LuminaTest", "daily", ".md", "笔记"])
        }
        if text.contains("读取 LuminaTest-daily.md") {
            return hasSuccessfulTool("file.read_note") && observationAndAnswerContain(["今天完成 benchmark", "LuminaTest Daily", "fixture"])
        }
        if text.contains("追加今天的进展") {
            return noteText(named: "LuminaTest-daily.md", in: documentsDirectory).localizedCaseInsensitiveContains("进展") ||
                containsAny(evidence, ["已更新", "已追加"])
        }
        if text.contains("删除 LuminaTest-daily.md") {
            return !FileManager.default.fileExists(atPath: notesDirectory(in: documentsDirectory).appendingPathComponent("LuminaTest-daily.md").path)
        }
        if text.contains("分享刚才保存") {
            return hasSuccessfulTool("share.prepare") &&
                containsAny(outputText(for: "share.prepare") + evidence, ["分享内容已准备", "已准备", "分享"])
        }
        if text.contains("系统设置") { return hasSuccessfulTool("app.open_settings") && observationAndAnswerContain(["设置", "settings", "已打开"]) }
        if text.contains("电量") || text.contains("网络") || text.contains("存储") {
            return observationAndAnswerContain(["电量", "网络", "存储", "battery", "network", "storage", "低电量"])
        }
        if text.contains("改写成 3 条检查项") || text.contains("整理成待办列表") || text.contains("整理成一句摘要") {
            let transformedText = valueText(toolResults.last { $0.toolName == "text.transform" }?.output["text"])
            return hasSuccessfulTool("text.transform") &&
                (transformedText.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 ||
                 evidence.trimmingCharacters(in: .whitespacesAndNewlines).count > 8)
        }
        if text.contains("记录 42 元 LuminaTest 咖啡支出") {
            return ledgerTransactions.contains { transaction in
                containsAll(transaction.memo, ["LuminaTest", "咖啡"]) &&
                    transaction.amount.map { NSDecimalNumber(decimal: $0).doubleValue == 42 } == true
            }
        }
        if text.contains("查最近的 LuminaTest 咖啡支出") || text.contains("汇总这个月 LuminaTest 咖啡") {
            return (hasSuccessfulTool("ledger.search") || hasSuccessfulTool("ledger.summary")) && observationAndAnswerContain(["LuminaTest", "咖啡", "42", "40"])
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
            return hasSuccessfulTool("subscription.list") && observationAndAnswerContain(["example.com", "订阅", "RSS"])
        }
        if text.contains("删除 LuminaTest example 这个订阅源") {
            return !subscriptions.contains { $0.source.localizedCaseInsensitiveContains("LuminaTest") || $0.source.localizedCaseInsensitiveContains("example") }
        }
        if text.contains("https://example.com") {
            return hasSuccessfulTool("webpage.fetch_text") && observationAndAnswerContain(["Example Domain", "example.com", "LuminaTest web"])
        }
        if text.contains("LuminaTest-report.md") {
            return hasSuccessfulTool("document.read_text") && observationAndAnswerContain(["LuminaTest report", "benchmark covers", "runtime execution"])
        }
        if text.contains("图片") {
            return (hasSuccessfulTool("image.extract_text") || hasSuccessfulTool("image.describe_metadata")) && observationAndAnswerContain(["LuminaTest image", "640", "360", "12345", "文字"])
        }
        if text.contains("12*(8+3)-5") {
            return hasSuccessfulTool("calculator.evaluate") && toolOutputAndAnswerContain("calculator.evaluate", ["127"])
        }
        return !toolResults.isEmpty && evidence.trimmingCharacters(in: .whitespacesAndNewlines).count > 8
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

private func benchmarkToolResults(from result: LuminaAgentRunResult) -> [LuminaToolResult] {
    guard let observations = result.reactTrace?.observations, !observations.isEmpty else {
        return result.toolResults
    }
    return observations.reduce(into: [LuminaToolResult]()) { results, observation in
        let output = benchmarkOutput(from: observation)
        guard results.last.map({ sameBenchmarkObservation($0, observation, output: output) }) != true else { return }
        results.append(LuminaToolResult(
            callID: UUID(),
            toolName: observation.toolName,
            status: observation.status,
            output: output,
            content: [.text(observation.summary)],
            errorMessage: observation.errorMessage
        ))
    }
}

private func benchmarkOutput(from observation: LuminaReActObservation) -> [String: LuminaJSONValue] {
    var output = observation.output
    if observation.replayed {
        output["replayed"] = .bool(true)
    }
    if let duplicateOf = observation.duplicateOf {
        output["duplicate_of"] = .string(duplicateOf)
    }
    return output
}

private func sameBenchmarkObservation(
    _ result: LuminaToolResult,
    _ observation: LuminaReActObservation,
    output: [String: LuminaJSONValue]
) -> Bool {
    result.toolName == observation.toolName &&
        result.status == observation.status &&
        result.output == output &&
        result.errorMessage == observation.errorMessage
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
