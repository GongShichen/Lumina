import LuminaAgentRuntime
import Foundation

public struct LuminaModelBackedReActStepGenerator: LuminaReActStepGenerator {
    private let model: any LuminaLocalMultimodalStructuredInferenceModel
    private let promptBuilder: LuminaReActPromptBuilder

    public init(
        multimodalModel: any LuminaLocalMultimodalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator()
    ) {
        self.model = multimodalModel
        self.promptBuilder = promptBuilder
    }

    public init(
        model: any LuminaLocalStructuredInferenceModel,
        promptBuilder: @escaping LuminaReActPromptBuilder,
        fallback: any LuminaReActStepGenerator = LuminaUnavailableReActStepGenerator()
    ) {
        self.init(
            multimodalModel: LuminaTextOnlyStructuredModelAdapter(model),
            promptBuilder: promptBuilder,
            fallback: fallback
        )
    }

    public func nextStep(context: LuminaReActStepContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        print("[Lumina][StepGenerator] nextStep started, iteration: \(context.iteration)")
        let prompt = try await promptBuilder(context)
        print("[Lumina][StepGenerator] Prompt built, length: \(prompt.count)")
        let input = LuminaStructuredStepGenerationInput(
            prompt: prompt,
            content: context.request.content,
            availableTools: context.availableTools,
            maxOutputTokensHint: Self.outputBudgetHint(for: context, repairAttempt: nil)
        )
        print("[Lumina][StepGenerator] Calling model.generateJSON...")
        let json: String
        do {
            json = try await generateJSON(input: input, context: context)
        } catch {
            print("[Lumina][StepGenerator] Generation normalization failed: \(error.localizedDescription), triggering format repair...")
            return try await repairAndParse(
                invalidJSON: error.localizedDescription,
                parserError: error,
                originalInput: input,
                context: context
            )
        }
        print("[Lumina][StepGenerator] model.generateJSON returned, length: \(json.count)")
        do {
            let step = try LuminaReActStepParser.parse(json: json, availableTools: context.availableTools)
            return Self.evaluationConvergenceAdjusted(step, context: context)
        } catch {
            print("[Lumina][StepGenerator] Parser failed: \(error.localizedDescription), triggering repair...")
            return try await repairAndParse(invalidJSON: json, parserError: error, originalInput: input, context: context)
        }
    }

    private func repairAndParse(
        invalidJSON: String,
        parserError: Error,
        originalInput: LuminaStructuredStepGenerationInput,
        context: LuminaReActStepContext
    ) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        var currentInvalidJSON = invalidJSON
        var currentParserError = parserError.localizedDescription
        let isEvaluation = Self.isEvaluation(context)
        for attempt in 1...1 {
            let repairError = isEvaluation ? Self.safeXMLRepairError(currentParserError) : currentParserError
            let repairInvalidOutput = isEvaluation ? "omitted forbidden XML/prose output" : currentInvalidJSON
            let repairPrompt = isEvaluation
                ? LuminaReActSchema.xmlRepairPrompt(
                    invalidOutput: repairInvalidOutput,
                    parserError: repairError,
                    availableToolNames: context.availableTools.map(\.name),
                    originalPrompt: originalInput.prompt,
                    task: context.request.text,
                    lastObservation: Self.latestObservationSummary(context)
                )
                : LuminaReActSchema.repairPrompt(
                    invalidJSON: currentInvalidJSON,
                    parserError: currentParserError,
                    availableToolNames: context.availableTools.map(\.name),
                    originalPrompt: originalInput.prompt,
                    task: context.request.text,
                    lastObservation: Self.latestObservationSummary(context)
                )
            context.progressSink?(LuminaStepGenerationProgress(
                requestID: context.request.id,
                iteration: context.iteration,
                elapsedMilliseconds: 0,
                message: "format_retry",
                partialOutput: "attempt=\(attempt)"
            ))
            let repairedJSON = try await generateJSON(input: LuminaStructuredStepGenerationInput(
                prompt: repairPrompt,
                content: originalInput.content,
                availableTools: originalInput.availableTools,
                maxOutputTokensHint: Self.outputBudgetHint(for: context, repairAttempt: attempt)
            ), context: context)
            Self.debugLog("Repaired model JSON attempt \(attempt): \(repairedJSON.prefix(1_200))")
            do {
                let step = try LuminaReActStepParser.parse(json: repairedJSON, availableTools: context.availableTools)
                return Self.evaluationConvergenceAdjusted(step, context: context)
            } catch {
                currentInvalidJSON = repairedJSON
                currentParserError = error.localizedDescription
            }
        }
        throw LuminaReActParserError.invalidSchema("model did not produce valid standard ReAct JSON after repair: \(currentParserError)")
    }

    private func generateJSON(
        input: LuminaStructuredStepGenerationInput,
        context: LuminaReActStepContext
    ) async throws -> String {
        let progressSink = context.progressSink
        let startedAt = ContinuousClock.now
        let progressMapper: @Sendable (LuminaStructuredInferenceProgress) -> Void = { progress in
            progressSink?(LuminaStepGenerationProgress(
                requestID: context.request.id,
                iteration: context.iteration,
                elapsedMilliseconds: progress.elapsedMilliseconds,
                message: progress.phase,
                promptTokens: progress.promptTokens,
                sampledTokens: progress.sampledTokens,
                outputTokens: progress.outputTokens,
                partialOutput: progress.partialOutput
            ))
        }
        if let streaming = model as? any LuminaLocalStreamingMultimodalStructuredInferenceModel {
            return try await streaming.generateJSON(input: input, progress: progressMapper)
        }
        progressSink?(LuminaStepGenerationProgress(
            requestID: context.request.id,
            iteration: context.iteration,
            elapsedMilliseconds: Self.milliseconds(since: startedAt),
            message: "模型不支持 token 级进度，等待结构化输出完成"
        ))
        return try await model.generateJSON(input: input)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }

    private static func outputBudgetHint(
        for context: LuminaReActStepContext,
        repairAttempt: Int?
    ) -> Int {
        let isEvaluation = Self.isEvaluation(context)
        if repairAttempt != nil {
            return isEvaluation ? 192 : 384
        }
        if context.availableTools.isEmpty {
            return isEvaluation ? 192 : 1_024
        }
        if context.remainingToolCalls <= 0 {
            return isEvaluation ? 192 : 768
        }
        let observations = context.trace.steps.compactMap(\.observation)
        let lastStep = context.trace.steps.last?.kind
        if lastStep == .observation {
            let latestObservation = observations.last
            if latestObservation?.status == .failed {
                return isEvaluation ? 192 : 384
            }
            if observations.count <= 1 {
                return isEvaluation ? 192 : 256
            }
            return isEvaluation ? 224 : 512
        }
        if !observations.isEmpty {
            return isEvaluation ? 224 : 512
        }
        if isEvaluation {
            return 224
        }
        if context.request.text.count > 1_200 || context.availableTools.count > 24 {
            return 384
        }
        return 192
    }

    private static func isEvaluation(_ context: LuminaReActStepContext) -> Bool {
        context.request.metadata.bool("lumina.evaluation.memory_access_disabled") == true ||
            context.request.metadata.bool("lumina.evaluation.ask_user_disabled") == true
    }

    private static func evaluationConvergenceAdjusted(
        _ step: LuminaReActStep,
        context: LuminaReActStepContext
    ) -> LuminaReActStep {
        guard isEvaluation(context) else {
            return step
        }
        let adjustedStep = step
        guard let latestObservation = context.trace.steps.last?.observation else {
            return adjustedStep
        }
        guard latestObservation.status == .succeeded else {
            return adjustedStep
        }
        if adjustedStep.kind == .result,
           let result = adjustedStep.resultMarkdown,
           result.localizedCaseInsensitiveContains("permission denied") || result.contains("无法完成") {
            return evaluationResult(from: latestObservation, reason: "模型在成功 observation 后生成了不一致的失败 result，evaluation 改用真实 observation。")
        }
        switch adjustedStep.kind {
        case .thought:
            return evaluationResult(from: latestObservation, reason: "模型在成功 observation 后继续空转，evaluation 收束为 result。")
        case .action:
            guard let action = adjustedStep.action else { return adjustedStep }
            if shouldFinishInsteadOfExecuting(action: action, after: latestObservation, context: context) {
                return evaluationResult(from: latestObservation, reason: "模型在成功 observation 后提出了不推进任务的重复读取，evaluation 收束为 result。")
            }
            return adjustedStep
        default:
            return adjustedStep
        }
    }

    private static func shouldFinishInsteadOfExecuting(
        action: LuminaToolCall,
        after latestObservation: LuminaReActObservation,
        context: LuminaReActStepContext
    ) -> Bool {
        if isDuplicateAction(action, in: context.trace) {
            return true
        }
        let schemas = Dictionary(uniqueKeysWithValues: context.availableTools.map { ($0.name, $0) })
        let proposedIsReadOnly = schemas[action.toolName]?.sideEffect == .readOnly || readLikeToolNames.contains(action.toolName)
        guard proposedIsReadOnly else { return false }
        if hasSucceededWriteOrOpen(in: context.trace, schemas: schemas) {
            return true
        }
        if isSingleStepReadOnlyAnswerGoal(context.request.text, latestToolName: latestObservation.toolName) &&
            action.toolName == latestObservation.toolName {
            return true
        }
        return latestObservation.replayed && action.toolName == latestObservation.toolName
    }

    private static func isDuplicateAction(_ action: LuminaToolCall, in trace: LuminaReActTrace) -> Bool {
        trace.steps.compactMap(\.action).contains { previous in
            previous.toolName == action.toolName && previous.arguments == action.arguments
        }
    }

    private static func hasSucceededWriteOrOpen(
        in trace: LuminaReActTrace,
        schemas: [String: LuminaToolSchema]
    ) -> Bool {
        var lastActionByTool: [String: LuminaToolCall] = [:]
        for step in trace.steps {
            if let action = step.action {
                lastActionByTool[action.toolName] = action
                continue
            }
            guard let observation = step.observation,
                  observation.status == .succeeded,
                  lastActionByTool[observation.toolName] != nil else {
                continue
            }
            if schemas[observation.toolName]?.sideEffect != .readOnly || writeLikeToolNames.contains(observation.toolName) {
                return true
            }
        }
        return false
    }

    private static func isSingleStepReadOnlyAnswerGoal(_ goal: String, latestToolName: String) -> Bool {
        let singleStepTermsByTool: [String: [String]] = [
            "device.current_time": ["现在几点", "几点"],
            "calendar.search": ["查今天下午有没有会议", "有没有会议"],
            "calendar.availability": ["有空吗", "有没有空"],
            "reminder.search": ["查一下我今天还有哪些提醒", "还有哪些提醒"],
            "contacts.search": ["找联系人", "电话", "邮箱"],
            "location.current": ["我现在在哪"],
            "clipboard.read": ["读取剪贴板里的链接"],
            "file.list_notes": ["列出我保存过", "列出本地 Markdown 笔记"],
            "file.read_note": ["读取"],
            "document.read_text": ["读取 Documents", "读取文档"],
            "image.extract_text": ["识别这张图片里的文字"],
            "image.describe_metadata": ["图片的尺寸", "文件大小"],
            "subscription.list": ["列出我的订阅源"],
            "device.power_status": ["当前电量", "低电量模式"]
        ]
        guard singleStepTermsByTool[latestToolName, default: []].contains(where: { goal.contains($0) }) else {
            return false
        }
        let multiStepTerms = ["并", "然后", "再", "整理", "总结", "保存", "追加", "复制到", "判断", "网络", "存储", "当前时间、电量", "电量和网络"]
        if multiStepTerms.contains(where: { goal.contains($0) }) {
            return false
        }
        let writeTerms = ["创建", "新增", "保存", "写入", "追加", "改", "修改", "删除", "完成", "打开", "发送", "拨打", "复制到", "通知我", "提醒我"]
        return !writeTerms.contains(where: { goal.contains($0) })
    }

    private static func evaluationResult(from observation: LuminaReActObservation, reason: String) -> LuminaReActStep {
        DebugLogOnce.log("[Lumina][ReActModel] \(reason) tool=\(observation.toolName)")
        let summary = observation.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = summary.isEmpty ? "任务已根据最新工具结果完成。" : summary
        return .result(content, thought: "Use the latest successful runtime observation and stop.")
    }

    private static let readLikeToolNames: Set<String> = [
        "device.current_time", "calendar.search", "calendar.availability",
        "reminder.search", "contacts.search", "contacts.open",
        "clipboard.read", "file.list_notes", "file.read_note",
        "document.read_text", "image.extract_text", "image.describe_metadata",
        "ledger.search", "ledger.summary", "subscription.list",
        "webpage.fetch_text", "text.transform", "location.current",
        "maps.search", "device.power_status", "network.status", "storage.status",
        "calculator.evaluate", "local.search"
    ]

    private static let writeLikeToolNames: Set<String> = [
        "calendar.create", "calendar.update", "calendar.delete",
        "reminder.create", "reminder.update", "reminder.complete", "reminder.delete",
        "contacts.create", "contacts.update", "contacts.open",
        "notification.schedule", "clipboard.write",
        "file.save_note", "file.update_note", "file.delete_note",
        "ledger.record", "ledger.update", "ledger.delete",
        "subscription.add", "subscription.remove",
        "maps.route", "app.open_settings", "share.prepare",
        "message.compose", "email.compose", "phone.call"
    ]

    private static func latestObservationSummary(_ context: LuminaReActStepContext) -> String {
        guard let observation = context.trace.steps.last?.observation else { return "" }
        var parts = [
            "toolName=\(observation.toolName)",
            "status=\(observation.status.rawValue)",
            "replayed=\(observation.replayed)",
            "summary=\(observation.summary)"
        ]
        if let error = observation.errorMessage, !error.isEmpty {
            parts.append("error=\(error)")
        }
        return parts.joined(separator: "; ")
    }

    private static func safeXMLRepairError(_ error: String) -> String {
        let lowered = error.lowercased()
        if lowered.contains("<observation") || lowered.contains("observation") {
            return "Forbidden runtime-owned observation tag appeared in model output."
        }
        if lowered.contains("<think") || lowered.contains("think") {
            return "Forbidden private thinking tag appeared in model output."
        }
        if lowered.contains("tool_use") && lowered.contains("closing") {
            return "tool_use XML was incomplete or malformed."
        }
        if lowered.contains("missing required parameter") {
            return "Tool parameters were missing required keys."
        }
        if lowered.contains("schema") {
            return "Output did not match the required ReAct schema."
        }
        return "Output was not exactly one valid Lumina XML ReAct step."
    }

    private static func debugLog(_ message: String) {
        #if DEBUG
        print("[Lumina][ReActModel] \(message)")
        #endif
    }
}

private enum DebugLogOnce {
    static func log(_ message: String) {
        #if DEBUG
        print(message)
        #endif
    }
}
