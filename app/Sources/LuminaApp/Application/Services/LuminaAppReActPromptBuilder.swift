import LuminaAgentRuntime
import Foundation

struct LuminaAppReActPromptBuilder: Sendable {
    var maximumTraceObservations: Int = 2
    var maximumContextCharacters: Int = 1_200
    var maximumTraceCharacters: Int = 900
    var maximumToolDescriptionCharacters: Int = 0
    var maximumFocusedToolDetails: Int = 8

    func build(context: LuminaReActStepContext) async throws -> String {
        try Task.checkCancellation()
        let profile = promptProfile(from: context.request.metadata)
        let isEvaluation = evaluationMode(in: context.request.metadata)
        let toolBlock = compactToolNameContext(for: context.availableTools)
        let focusedToolBlock = focusedToolContext(for: context, isEvaluation: isEvaluation)
        let traceBlock = try compactTraceContext(context.trace, isEvaluation: isEvaluation)
        let contextBlock = loadedContextBlock(context.loadedContext, isEvaluation: isEvaluation)
        let modalities = context.request.content.modalities.map(\.rawValue).sorted().joined(separator: ", ")
        let contract = isEvaluation
            ? #"JSON only. Use {"type":"tool_use","thought":"...","tool_name":"exact.name","parameters":{},"requires_confirmation":false} or {"type":"final_answer","thought":"...","content":"markdown"}. Tool names from T. No prose, no observation, no tool_call/function/arguments/input."#
            : LuminaReActSchema.compactPromptContract
        let examples = isEvaluation ? "" : "\(formatExamples(for: profile, tools: context.availableTools))\n"
        let profileText = profileInstructions(for: profile, metadata: context.request.metadata, isEvaluation: isEvaluation)
        let rulesText = isEvaluation
            ? "Use tools to progress; do not claim success before O."
            : "Rules: finish tasks end-to-end; if a tool can make progress output the standard tool_use object; if ask_user is available and required info is missing, use ask_user; if ask_user is unavailable, explain the missing info in final_answer; never claim success before runtime observation; after a useful observation either call the next needed tool or output final_answer; never output observation yourself; final_answer uses content."
        let openAIWarning = isEvaluation
            ? ""
            : "\nDo not output OpenAI-style tool calls. Do not output {\"type\":\"tool_call\"}. Do not output function/args/arguments/input keys."
        let labels = isEvaluation
            ? ("T", "S", "C", "O", "U", "M", "B")
            : ("Tools(all)", "ToolSchemas", "Ctx", "Obs", "User", "Mods", "Budget")

        return """
        \(contract)
        \(systemPrompt(for: profile))
        \(examples)\(rulesText)
        \(profileText)\(openAIWarning)
        \(labels.0): \(toolBlock)
        \(labels.1): \(focusedToolBlock)
        \(labels.2): \(contextBlock)
        \(labels.3): \(traceBlock)
        \(labels.4): \(context.request.text)
        \(labels.5): \(modalities.isEmpty ? "text" : modalities)
        \(labels.6): iter=\(context.iteration), tools=\(context.remainingToolCalls), obsChars=\(context.maximumObservationCharacters)
        """
    }

    private func promptProfile(from metadata: [String: LuminaJSONValue]) -> LuminaAppPromptProfile {
        metadata.string(LuminaAppPromptProfile.metadataKey)
            .flatMap(LuminaAppPromptProfile.init(rawValue:)) ?? .taskExecution
    }

    private func systemPrompt(for profile: LuminaAppPromptProfile) -> String {
        switch profile {
        case .taskExecution:
            return """
            You are Lumina, a local-first Apple-platform assistant. Use ReAct tools to complete the task privately.
            """
        case .homePersonalization:
            return """
            You generate Lumina home copy from real local status and tool schemas.
            """
        }
    }

    private func profileInstructions(for profile: LuminaAppPromptProfile, metadata: [String: LuminaJSONValue], isEvaluation: Bool) -> String {
        switch profile {
        case .taskExecution:
            if isEvaluation {
                return "Policy: relative time -> device.current_time first; writes/open/send -> requires_confirmation=true; memory/ask_user disabled."
            }
            let memoryPolicy = memoryAccessDisabled(in: metadata) ? """
            - Memory disabled; do not use memory tools.
            """ : """
            - Save durable memory only via memory.ingest_text when the user asks or a stable reusable fact/preference appears; do not save transient state.
            """
            let askUserPolicy = askUserDisabled(in: metadata) ? """
            - ask_user disabled for this evaluation run; do not ask follow-up questions. If information is missing, use conservative defaults or final_answer with the missing fields.
            """ : """
            - ask_user may be used when required details are missing and no safe default exists.
            """
            return """
            Task policy:
            - Relative date/time needs device.current_time first.
            - Side-effect tools may require confirmation; set requires_confirmation=true when writing/opening/sending.
            \(memoryPolicy)
            \(askUserPolicy)
            """
        case .homePersonalization:
            return """
            Home policy:
            - Read-only only. Never fabricate people/events/bills/memory.
            - Max 3: SUGGESTION|title|query|SF Symbol
            """
        }
    }

    private func formatExamples(for profile: LuminaAppPromptProfile, tools: [LuminaToolSchema]) -> String {
        let names = Set(tools.map(\.name))
        var examples: [String] = []
        if names.contains("device.current_time") {
            examples.append("""
            Example no observation:
            User: 现在几点？
            JSON: {"type":"tool_use","thought":"Need current device time.","tool_name":"device.current_time","parameters":{},"requires_confirmation":false}
            Example after observation:
            Obs: Observation(runtime-only; never output this type): device.current_time succeeded summary=已读取本机时间：2026-05-25 21:51:48 Asia/Shanghai
            JSON: {"type":"final_answer","thought":"Time was observed.","content":"现在是 2026-05-25 21:51:48，时区 Asia/Shanghai。"}
            """)
        }
        if profile == .taskExecution, names.contains("ask_user") {
            examples.append("""
            Example missing required info:
            User: 帮我安排一下
            JSON: {"type":"ask_user","thought":"Need user preference before continuing.","reason":"缺少安排偏好","questions":[{"id":"preference","question":"你想优先安排哪类事情？","options":[{"label":"工作","description":"优先整理工作任务"},{"label":"生活","description":"优先整理生活事项"}]}],"sensitivity":"normal","timeout_seconds":120,"allow_custom_answer":true}
            """)
        }
        guard !examples.isEmpty else { return "Examples: none" }
        return "Format few-shot examples:\n" + examples.joined(separator: "\n")
    }

    private func memoryAccessDisabled(in metadata: [String: LuminaJSONValue]) -> Bool {
        metadata.bool(LuminaAppContextProvider.disableMemoryContextMetadataKey) == true ||
            metadata.bool("lumina.evaluation.memory_access_disabled") == true
    }

    private func askUserDisabled(in metadata: [String: LuminaJSONValue]) -> Bool {
        metadata.bool("lumina.evaluation.ask_user_disabled") == true
    }

    private func evaluationMode(in metadata: [String: LuminaJSONValue]) -> Bool {
        metadata.bool("lumina.evaluation.memory_access_disabled") == true ||
            metadata.bool("lumina.evaluation.ask_user_disabled") == true
    }

    private func compactToolNameContext(for schemas: [LuminaToolSchema]) -> String {
        schemas.sorted { $0.name < $1.name }.map { schema in
            schema.name
        }.joined(separator: "; ")
    }

    private func focusedToolContext(for context: LuminaReActStepContext, isEvaluation: Bool) -> String {
        let selected = focusedTools(
            for: context.request.text,
            schemas: context.availableTools,
            profile: promptProfile(from: context.request.metadata),
            limit: isEvaluation ? 5 : maximumFocusedToolDetails
        )
        guard !selected.isEmpty else { return "none" }
        return selected.map { schema in
            let params = schema.parameters.map { parameter in
                "\(parameter.name):\(Self.shortType(parameter.type))\(parameter.required ? "" : "?")"
            }.joined(separator: ", ")
            let input = params.isEmpty ? "{}" : "{\(params)}"
            let sideEffect = schema.sideEffect == .readOnly ? "r" : "w"
            let sensitivity = Self.shortSensitivity(schema.sensitivity)
            let description = maximumToolDescriptionCharacters > 0
                ? "|\(schema.description.truncated(to: maximumToolDescriptionCharacters))"
                : ""
            return "\(schema.name)|\(sideEffect)|\(sensitivity)|\(input)\(description)"
        }.joined(separator: "; ")
    }

    private func focusedTools(
        for request: String,
        schemas: [LuminaToolSchema],
        profile: LuminaAppPromptProfile,
        limit: Int
    ) -> [LuminaToolSchema] {
        let query = request.lowercased()
        let alwaysUseful: Set<String> = profile == .homePersonalization
            ? ["device.current_time", "memory.stats", "memory.recent"]
            : ["ask_user", "device.current_time"]
        let scored = schemas.map { schema in
            (schema, focusScore(schema: schema, query: query, alwaysUseful: alwaysUseful))
        }
        .filter { $0.1 > 0 }
        .sorted {
            if $0.1 == $1.1 { return $0.0.name < $1.0.name }
            return $0.1 > $1.1
        }
        return Array(scored.prefix(limit).map(\.0))
    }

    private func focusScore(schema: LuminaToolSchema, query: String, alwaysUseful: Set<String>) -> Int {
        var score = alwaysUseful.contains(schema.name) ? 60 : 0
        let searchable = "\(schema.name) \(schema.description) \(schema.parameters.map(\.name).joined(separator: " "))".lowercased()
        for token in query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) where token.count >= 2 {
            if searchable.contains(token) { score += 12 }
        }
        for keyword in Self.capabilityKeywords[schema.name, default: []] where query.contains(keyword) {
            score += 30
        }
        if schema.sideEffect != .readOnly,
           ["创建", "新增", "保存", "写入", "修改", "删除", "完成", "打开", "发送", "通知", "提醒", "安排"].contains(where: query.contains) {
            score += 4
        }
        return score
    }

    private static func shortType(_ type: LuminaToolParameterType) -> String {
        switch type {
        case .string:
            return "s"
        case .number:
            return "n"
        case .bool:
            return "b"
        case .object:
            return "o"
        case .array:
            return "a"
        case .dateISO8601:
            return "d"
        }
    }

    private static func shortSensitivity(_ sensitivity: LuminaToolSensitivity) -> String {
        switch sensitivity {
        case .low:
            return "l"
        case .normal:
            return "n"
        case .sensitive:
            return "s"
        case .privateData:
            return "p"
        }
    }

    private static let capabilityKeywords: [String: [String]] = [
        "device.current_time": ["几点", "现在", "时间", "今天", "明天", "后天", "上午", "下午", "晚上", "分钟后", "小时后"],
        "calendar.search": ["日程", "会议", "安排", "空闲", "忙", "日历"],
        "calendar.create": ["创建日程", "定一个日程", "安排", "会议", "日历"],
        "calendar.update": ["修改日程", "改日程", "调整日程"],
        "calendar.delete": ["删除日程", "取消日程"],
        "calendar.availability": ["有空", "忙闲", "空闲", "冲突"],
        "reminder.create": ["提醒", "待办", "叫我", "别忘"],
        "reminder.search": ["查提醒", "提醒事项", "待办"],
        "reminder.update": ["修改提醒", "改提醒"],
        "reminder.complete": ["完成提醒", "完成待办"],
        "reminder.delete": ["删除提醒", "取消提醒"],
        "notification.schedule": ["通知", "稍后通知", "提醒我"],
        "contacts.search": ["联系人", "电话", "邮箱", "找人"],
        "contacts.create": ["新建联系人", "保存联系人"],
        "contacts.update": ["修改联系人"],
        "contacts.open": ["打开联系人"],
        "message.compose": ["短信", "发消息", "信息"],
        "email.compose": ["邮件", "email", "邮箱"],
        "phone.call": ["打电话", "呼叫", "facetime"],
        "location.current": ["位置", "在哪", "附近", "经纬度"],
        "maps.search": ["地图", "搜索地点", "附近"],
        "maps.route": ["导航", "路线", "去"],
        "clipboard.read": ["剪贴板", "粘贴板", "复制"],
        "clipboard.write": ["写入剪贴板", "复制到剪贴板"],
        "file.save_note": ["保存文件", "保存成文件", "导出", "笔记"],
        "file.list_notes": ["文件列表", "笔记列表"],
        "file.read_note": ["读取文件", "读笔记"],
        "file.update_note": ["更新文件", "修改笔记"],
        "file.delete_note": ["删除文件", "删除笔记"],
        "document.read_text": ["读取文档", "pdf", "markdown", "文本文件"],
        "image.extract_text": ["图片文字", "ocr", "识别文字"],
        "image.describe_metadata": ["图片信息", "图片尺寸"],
        "url.open": ["打开链接", "打开网页", "设置"],
        "app.open_settings": ["设置", "权限设置"],
        "share.prepare": ["分享", "发送到"],
        "ledger.record": ["记账", "支出", "收入", "花了"],
        "ledger.search": ["查账", "支出", "账目"],
        "ledger.summary": ["账单汇总", "消费汇总"],
        "ledger.update": ["修改账目"],
        "ledger.delete": ["删除账目"],
        "subscription.add": ["订阅", "rss"],
        "subscription.list": ["订阅列表"],
        "subscription.refresh": ["刷新订阅"],
        "subscription.remove": ["取消订阅", "删除订阅"],
        "webpage.fetch_text": ["网页", "抓取网页", "读取网页"],
        "webpage.save_to_memory": ["保存网页", "记住网页"],
        "calculator.evaluate": ["计算", "算一下", "等于"],
        "text.transform": ["总结", "改写", "翻译", "润色"],
        "device.power_status": ["电量", "充电", "低电量", "发热"],
        "network.status": ["网络", "联网", "wifi", "蜂窝"],
        "storage.status": ["存储", "空间", "容量"],
        "memory.ingest_text": ["记住", "保存到记忆", "记忆"],
        "memory.recent": ["最近记忆"],
        "memory.stats": ["记忆数量", "memory"],
        "memory.delete": ["删除记忆"],
        "ask_user": ["帮我计划", "不确定", "随便", "你决定"]
    ]

    private func loadedContextBlock(_ loadedContext: LuminaRuntimeContext, isEvaluation: Bool) -> String {
        guard !loadedContext.sections.isEmpty else {
            return "none; retrieve with tools if needed"
        }
        let sections = loadedContext.sections.enumerated().map { index, section in
            let content = section.content.isEmpty ? section.summary : section.content
            return "[\(index + 1)] \(section.title) source=\(section.source) sens=\(section.sensitivity.rawValue) summary=\(content.truncated(to: 240))"
        }.joined(separator: "\n")
        return sections.truncated(to: isEvaluation ? 400 : maximumContextCharacters)
    }

    private func compactTraceContext(_ trace: LuminaReActTrace, isEvaluation: Bool) throws -> String {
        let compactSteps = trace.steps.suffix((isEvaluation ? 1 : maximumTraceObservations) * 2)
        let lines = compactSteps.compactMap { step -> String? in
            switch step.kind {
            case .thought:
                guard let thought = step.thought, !thought.isEmpty else { return nil }
                return "Thought(model): \(thought.truncated(to: 180))"
            case .action:
                guard let action = step.action else { return nil }
                return "ToolUse(model): \(action.toolName) params=\(action.arguments.compactModelTraceValue.truncated(to: 240))"
            case .observation:
                guard let observation = step.observation else { return nil }
                let error = observation.errorMessage.map { " error=\($0.truncated(to: 120))" } ?? ""
                return "Observation(runtime-only; never output this type): \(observation.toolName) \(observation.status.rawValue) summary=\(observation.summary.truncated(to: 240))\(error)"
            case .final:
                guard let final = step.finalMarkdown else { return nil }
                return "Final(model): \(final.truncated(to: 180))"
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? "none" : text.truncated(to: isEvaluation ? 420 : maximumTraceCharacters)
    }
}
