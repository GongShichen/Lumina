import LuminaAgentRuntime
import Foundation
import LuminaModelRuntime

@MainActor
final class LuminaInAppAgenticRLRunner {
    typealias ProgressHandler = @MainActor (LuminaAgenticRLSnapshot) -> Void

    private let services: AgentAppServices
    private let reportDirectory: URL

    init(services: AgentAppServices, reportDirectory: URL) {
        self.services = services
        self.reportDirectory = reportDirectory
    }

    func run(taskCount: Int = 200, progress: @escaping ProgressHandler) async -> LuminaAgenticRLReport {
        let tasks = LuminaAgenticRLSuite.makeTasks(count: taskCount)
        progress(LuminaAgenticRLSnapshot(state: .running, currentTask: "准备生成 Agentic RL JSONL 轨迹", completed: 0, total: tasks.count))
        var records: [LuminaAgenticRLTrajectoryRecord] = []
        let outputURLs = makeOutputURLs()
        prepareJSONL(at: outputURLs.jsonl)

        for task in tasks {
            if Task.isCancelled { break }
            progress(LuminaAgenticRLSnapshot(state: .running, currentTask: task.instruction, completed: records.count, total: tasks.count, latestTool: task.expectedTools.last))
            services.beginSession()
            let metricsMark = services.modelMetrics.mark()
            let (result, observedTimings) = await runSingleTask(task, completed: records.count, total: tasks.count, progress: progress)
            let metrics = services.modelMetrics.metrics(after: metricsMark)
            let record = makeRecord(task: task, result: result, observedTimings: observedTimings, modelMetrics: metrics)
            records.append(record)
            appendJSONL(record, to: outputURLs.jsonl)
            progress(LuminaAgenticRLSnapshot(state: .running, currentTask: task.instruction, completed: records.count, total: tasks.count, latestTool: record.actualTools.last ?? task.expectedTools.last))
        }

        let report = LuminaAgenticRLReport.make(records: records, trajectoryJSONLURL: outputURLs.jsonl, summaryJSONURL: outputURLs.summary)
        writeSummary(report, records: records, to: outputURLs.summary)
        progress(LuminaAgenticRLSnapshot(state: Task.isCancelled ? .cancelled : .finished, currentTask: "Agentic RL 轨迹已导出", completed: records.count, total: tasks.count, report: report))
        return report
    }

    private func runSingleTask(
        _ task: LuminaAgenticRLTask,
        completed: Int,
        total: Int,
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
        for await event in services.runEvaluationStream(content: [.text(task.instruction)]) {
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
                progress(LuminaAgenticRLSnapshot(
                    state: .running,
                    currentTask: "\(task.instruction) · 模型生成中 \(Self.elapsedText(since: taskStartedAt))\(promptText)\(outputText)",
                    completed: completed,
                    total: total,
                    latestTool: latestActivity
                ))
            }
            if case let .actionProposed(call) = event {
                latestActivity = call.toolName
                progress(LuminaAgenticRLSnapshot(
                    state: .running,
                    currentTask: "\(task.instruction) · action \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .confirmationRequired(call) = event {
                latestActivity = "确认 \(call.toolName)"
                progress(LuminaAgenticRLSnapshot(
                    state: .running,
                    currentTask: "\(task.instruction) · 自动确认 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: latestActivity
                ))
            }
            if case let .toolStarted(call) = event {
                latestActivity = call.toolName
                progress(LuminaAgenticRLSnapshot(
                    state: .running,
                    currentTask: "\(task.instruction) · 执行 \(call.toolName)",
                    completed: completed,
                    total: total,
                    latestTool: call.toolName
                ))
            }
            if case let .toolFinished(result) = event {
                latestActivity = result.toolName
                progress(LuminaAgenticRLSnapshot(
                    state: .running,
                    currentTask: "\(task.instruction) · \(result.toolName) \(result.status.rawValue)",
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
            plan: LuminaAgentPlan(summary: "Agentic RL task cancelled before runtime finished.", toolCalls: []),
            toolResults: [],
            status: .cancelled
        )
        return (cancelled, observer.finish(result: cancelled))
    }

    private static func elapsedText(since start: ContinuousClock.Instant) -> String {
        let duration = start.duration(to: ContinuousClock.now)
        let milliseconds = Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.1fs", milliseconds / 1_000)
    }

    private func makeRecord(
        task: LuminaAgenticRLTask,
        result: LuminaAgentRunResult,
        observedTimings: LuminaObservedRunTimings,
        modelMetrics: [LuminaModelInferenceMetrics]
    ) -> LuminaAgenticRLTrajectoryRecord {
        let actualTools = result.toolResults.map(\.toolName)
        let expected = Set(task.expectedTools)
        let actual = Set(actualTools)
        let truePositive = Double(expected.intersection(actual).count)
        let falsePositive = Double(actual.subtracting(expected).count)
        let falseNegative = Double(expected.subtracting(actual).count)
        let precision = truePositive + falsePositive == 0 ? 0 : truePositive / (truePositive + falsePositive)
        let recall = truePositive + falseNegative == 0 ? 0 : truePositive / (truePositive + falseNegative)
        let f1 = precision + recall == 0 ? 0 : 2 * precision * recall / (precision + recall)
        let reward = result.status == .succeeded ? min(1, 0.35 + 0.65 * f1) : 0
        let final = result.reactTrace?.steps.last(where: { $0.kind == .result })?.resultMarkdown ?? result.plan.summary
        return LuminaAgenticRLTrajectoryRecord(
            id: "\(task.id)-\(result.requestID.uuidString)",
            schemaVersion: "lumina.agentic_rl.v1",
            createdAt: Date(),
            task: .init(
                id: task.id,
                instruction: task.instruction,
                category: task.category,
                expectedTools: task.expectedTools,
                difficulty: task.difficulty,
                cleanupPrefixes: task.cleanupPrefixes
            ),
            environment: .init(app: "Lumina", runtime: "ReAct", schemaVersion: "standard_tool_use_result", localOnly: true),
            messages: [
                .init(role: "user", content: task.instruction),
                .init(role: "assistant", content: final)
            ],
            steps: result.reactTrace?.steps.map(LuminaAgenticRLTrajectoryStep.make(from:)) ?? [],
            actualTools: actualTools,
            outcome: LuminaAgenticRLOutcome(
                status: result.status.rawValue,
                reward: reward,
                toolPrecision: precision,
                toolRecall: recall,
                toolF1: f1,
                activeRuntimeMilliseconds: observedTimings.activeRuntimeMilliseconds,
                wallClockMilliseconds: observedTimings.wallClockMilliseconds,
                confirmationWaitMilliseconds: observedTimings.confirmationWaitMilliseconds,
                systemPermissionWaitMilliseconds: observedTimings.systemPermissionWaitMilliseconds,
                totalMilliseconds: result.timing.totalMilliseconds,
                stepGenerationMilliseconds: result.timing.stepGenerationMilliseconds,
                toolMilliseconds: observedTimings.observedToolExecutionMilliseconds,
                memoryAccessDisabled: true,
                failureSummary: result.status == .succeeded ? nil : result.plan.summary
            ),
            modelMetrics: modelMetrics
        )
    }

    private func makeOutputURLs() -> (jsonl: URL, summary: URL) {
        let timestamp = Int(Date().timeIntervalSince1970)
        let directory = reportDirectory.appendingPathComponent("AgenticRL", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (
            directory.appendingPathComponent("LuminaAgenticRL-\(timestamp).jsonl"),
            directory.appendingPathComponent("LuminaAgenticRL-\(timestamp)-summary.json")
        )
    }

    private func prepareJSONL(at url: URL) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    private func appendJSONL(_ record: LuminaAgenticRLTrajectoryRecord, to url: URL) {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(record)
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.write(contentsOf: Data("\n".utf8))
            try handle.close()
        } catch {
            return
        }
    }

    private func writeSummary(_ report: LuminaAgenticRLReport, records: [LuminaAgenticRLTrajectoryRecord], to url: URL) {
        do {
            let payload = LuminaAgenticRLSummaryPayload(report: report, taskIDs: records.map(\.task.id))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(payload).write(to: url, options: .atomic)
        } catch {
            return
        }
    }
}
