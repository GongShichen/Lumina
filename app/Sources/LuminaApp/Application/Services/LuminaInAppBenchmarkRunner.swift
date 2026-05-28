import LuminaAgentRuntime
@preconcurrency import EventKit
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
        let traceLogger = LuminaBenchmarkTraceLogger(reportDirectory: reportDirectory)
        await traceLogger.record("benchmark_started", fields: [
            "taskCount": "\(tasks.count)",
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
            let toolAttempts = result.toolResults.map(\.toolName)
            let toolReplays = result.toolResults.filter { $0.output["replayed"]?.boolValue == true }.map(\.toolName)
            let actualTools = result.toolResults.filter { $0.output["replayed"]?.boolValue != true }.map(\.toolName)
            let expectedSet = Set(task.expectedTools)
            let actualSet = Set(actualTools)
            let missingTools = expectedSet.subtracting(actualSet).sorted()
            let unexpectedTools = actualSet.subtracting(expectedSet).sorted()
            let toolMismatchSummary = missingTools.isEmpty && unexpectedTools.isEmpty
                ? nil
                : "Expected tools did not match executions. missing=\(missingTools.joined(separator: ",")); unexpected=\(unexpectedTools.joined(separator: ","))"
            let failure = result.status == .succeeded ? toolMismatchSummary : result.plan.summary
            let taskResult = LuminaBenchmarkTaskResult(
                task: task,
                toolAttempts: toolAttempts,
                actualTools: actualTools,
                toolReplays: toolReplays,
                status: result.status.rawValue,
                totalMilliseconds: result.timing.totalMilliseconds,
                observedTimings: observedTimings,
                stepGenerationMilliseconds: result.timing.stepGenerationMilliseconds,
                toolMilliseconds: result.timing.toolExecutionMilliseconds,
                modelMetrics: services.modelMetrics.metrics(after: metricsMark),
                failureSummary: failure
            )
            results.append(taskResult)
            await traceLogger.record("task_finished", fields: [
                "taskID": task.id,
                "runtimeStatus": result.status.rawValue,
                "status": taskResult.status,
                "missingTools": missingTools.joined(separator: ","),
                "unexpectedTools": unexpectedTools.joined(separator: ","),
                "attempts": toolAttempts.joined(separator: ","),
                "executions": actualTools.joined(separator: ","),
                "replays": toolReplays.joined(separator: ","),
                "wallClockMs": String(format: "%.1f", observedTimings.wallClockMilliseconds),
                "activeMs": String(format: "%.1f", observedTimings.activeRuntimeMilliseconds),
                "modelMs": String(format: "%.1f", result.timing.stepGenerationMilliseconds),
                "toolMs": String(format: "%.1f", result.timing.toolExecutionMilliseconds),
                "final": result.plan.summary.truncated(to: 4_000),
                "toolResultCount": "\(result.toolResults.count)"
            ])
            progress(LuminaBenchmarkSnapshot(state: .running, currentTask: task.text, completed: results.count, total: tasks.count, latestTool: actualTools.last ?? task.expectedTools.last))
        }
        let reportURLs = writeReport(results: results)
        let report = LuminaBenchmarkReport.make(results: results, jsonReportURL: reportURLs.json, markdownReportURL: reportURLs.markdown)
        await traceLogger.record("benchmark_finished", fields: [
            "completed": "\(results.count)",
            "report": reportURLs.json?.path ?? "",
            "trace": await traceLogger.fileURL.path
        ])
        progress(LuminaBenchmarkSnapshot(state: Task.isCancelled ? .cancelled : .finished, currentTask: "Benchmark 完成", completed: results.count, total: tasks.count, report: report))
        return report
    }

    private func runSingleTask(
        _ task: LuminaBenchmarkTask,
        completed: Int,
        total: Int,
        traceLogger: LuminaBenchmarkTraceLogger,
        progress: @escaping ProgressHandler
    ) async -> (LuminaAgentRunResult, LuminaObservedRunTimings) {
        var finalResult: LuminaAgentRunResult?
        var observer = LuminaRunStreamObserver()
        var latestPromptTokens: Int?
        var latestSampledTokens = 0
        var latestOutputTokens = 0
        let taskStartedAt = ContinuousClock.now
        observer.start()
        for await event in services.runEvaluationStream(content: [.text(task.text)]) {
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
        case let .finalGenerated(markdown):
            fields["markdown"] = markdown.truncated(to: 4_000)
            await traceLogger.record("final_generated", fields: fields)
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
            "| \(result.taskID) | \(result.status) | \(format(result.f1)) | \(Int(result.activeRuntimeMilliseconds))ms | \(Int(result.wallClockMilliseconds))ms | \(Int(result.systemPermissionWaitMilliseconds))ms | \(result.toolAttemptCount) | \(result.toolExecutionCount) | \(result.toolReplayCount) | \(result.actualTools.joined(separator: ", ")) | \(result.modelMetrics.count) |"
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
        - Tool attempts / executions / replays: \(report.results.reduce(0) { $0 + $1.toolAttemptCount }) / \(report.results.reduce(0) { $0 + $1.toolExecutionCount }) / \(report.results.reduce(0) { $0 + $1.toolReplayCount })

        ## Model Inference
        - Model invocations: \(report.modelInvocationCount)
        - TTFT p50/p95: \(optionalMilliseconds(report.modelTTFTP50Milliseconds)) / \(optionalMilliseconds(report.modelTTFTP95Milliseconds))
        - Decode tokens/s p50/p95: \(optionalNumber(report.modelTokensPerSecondP50)) / \(optionalNumber(report.modelTokensPerSecondP95))
        - Prompt tokens p95: \(optionalNumber(report.modelPromptTokensP95))
        - Output tokens p95: \(optionalNumber(report.modelOutputTokensP95))

        ## Tasks
        | Task | Status | Tool F1 | Active latency | Wall clock | Permission wait | Attempts | Executions | Replays | Executed tools | Model calls |
        | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | ---: |
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

    private func prepareBenchmarkFixtures(traceLogger: LuminaBenchmarkTraceLogger) async {
        let eventStore = EKEventStore()
        do {
            try await requestBenchmarkCalendarAccess(eventStore)
            try await requestBenchmarkReminderAccess(eventStore)
            try createCalendarFixtureIfNeeded(eventStore)
            try createReminderFixtureIfNeeded(eventStore)
            await traceLogger.record("benchmark_fixtures_ready", fields: [
                "calendar": "LuminaTest 项目同步",
                "reminder": "LuminaTest 带伞"
            ])
        } catch {
            await traceLogger.record("benchmark_fixtures_failed", fields: [
                "error": error.localizedDescription
            ])
        }
    }

    private func requestBenchmarkCalendarAccess(_ eventStore: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            _ = try await eventStore.requestFullAccessToEvents()
        default:
            return
        }
    }

    private func requestBenchmarkReminderAccess(_ eventStore: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            _ = try await eventStore.requestFullAccessToReminders()
        default:
            return
        }
    }

    private func createCalendarFixtureIfNeeded(_ eventStore: EKEventStore) throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()) ?? Date().addingTimeInterval(86_400)
        let end = start.addingTimeInterval(1_800)
        let predicate = eventStore.predicateForEvents(withStart: start.addingTimeInterval(-3_600), end: end.addingTimeInterval(3_600), calendars: nil)
        let exists = eventStore.events(matching: predicate).contains {
            ($0.title ?? "").localizedCaseInsensitiveContains("LuminaTest 项目同步")
        }
        guard !exists else { return }
        let event = EKEvent(eventStore: eventStore)
        event.title = "LuminaTest 项目同步"
        event.notes = "Lumina benchmark fixture"
        event.startDate = start
        event.endDate = end
        event.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent, commit: true)
    }

    private func createReminderFixtureIfNeeded(_ eventStore: EKEventStore) throws {
        let status = EKEventStore.authorizationStatus(for: .reminder)
        guard status == .fullAccess || status == .writeOnly else { return }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = "LuminaTest 带伞"
        reminder.notes = "Lumina benchmark fixture"
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        let due = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Calendar.current.date(byAdding: .day, value: 1, to: Date()) ?? Date())
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
        }
        try eventStore.save(reminder, commit: true)
    }
}
