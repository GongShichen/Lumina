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
        let toolBlock = compactToolNameContext(for: context.availableTools, isEvaluation: isEvaluation)
        let focusedToolBlock = focusedToolContext(for: context, isEvaluation: isEvaluation)
        let observationRecoveryToolBlock = observationRecoveryToolContext(for: context, isEvaluation: isEvaluation)
        let traceBlock = try compactTraceContext(
            context.trace,
            visibleTools: context.availableTools,
            isEvaluation: isEvaluation
        )
        let contextBlock = loadedContextBlock(context.loadedContext, isEvaluation: isEvaluation)
        let hasRuntimeObservation = context.trace.steps.contains { $0.kind == .observation }
        let modalities = context.request.content.modalities.map(\.rawValue).sorted().joined(separator: ", ")
        let contract = isEvaluation
            ? """
            FIRST BYTES MUST BE <thought>. Output exactly one valid Lumina XML ReAct step and nothing else.
            No <think>, prose, markdown fences, JSON ReAct object, labels, schema text, or tool_call blocks.
            Tool step: <thought>why</thought><tool_use name="exact.name" requires_confirmation="false">{}</tool_use>
            Result step: <thought>done</thought><result>markdown answer</result>
            Blocker step: <thought>blocked</thought><cannot_complete>reason</cannot_complete>
            Final answers are not tools. Never use summary, text.summarize, answer, exact.name, summarize_*, close, done, write, or result as a tool name unless that exact name appears in Available tool names.
            In evaluation, ask_user is unavailable; use <cannot_complete> when required information is missing.
            Before any runtime result, call a relevant tool when it can progress the task; do not output result.
            After a runtime result, output <result> only when the whole user goal is complete. If another read/write/create/update/save/open/share operation is still required, call the next required tool.
            Observation output is authoritative. Use runtime-observed facts in final answers and recover from failed observations with corrected tool calls when possible.
            If a runtime result failed from an unknown tool, use the provided full tool schema and choose only an exact tool name from that schema.
            If a runtime result failed from schema or missing parameters, use the provided tool schema; fill missing parameters from the user goal or previous observations and retry with corrected JSON. Only output cannot_complete when the needed value cannot be inferred.
            If a runtime result failed from permission, cancellation, or a repeated identical call, do not blindly repeat it; recover with corrected parameters, a different valid tool, or cannot_complete.
            """
            : LuminaReActSchema.compactPromptContract
        let examples = (hasRuntimeObservation && !isEvaluation) ? "" : "\(formatExamples(for: profile, tools: context.availableTools, isEvaluation: isEvaluation))\n"
        let scopeText = evaluationScopeInstructions(metadata: context.request.metadata, tools: context.availableTools, isEvaluation: isEvaluation)
        let profileText = profileInstructions(for: profile, metadata: context.request.metadata, isEvaluation: isEvaluation)
        let nextStepDirective = nextStepDirective(for: context, isEvaluation: isEvaluation)
        let rulesText = isEvaluation
            ? "Use tools to progress. If focused tools contain a relevant tool, call it with the XML tool_use tag. Do not claim success before a real runtime Observation. After any Observation, decide from the full user goal: output result only if all requested operations are complete; otherwise call the next required tool. Observation is authoritative: use runtime-observed facts in final answers. Final answer is <result>, not a tool; never call summary, text.summarize, answer, exact.name, summarize_*, close, done, write, or result as a tool unless that exact name is in Available tool names. For read-only lookup/availability/status tasks, one successful matching read observation is usually enough: answer directly, do not call summarizer/answer/close tools. For create/new calendar or reminder tasks with relative time, call device.current_time only when no current-time observation exists; once time is observed, create the item. For update/delete/complete/open tasks that identify an item by title or name, first call the matching search/list tool with a query keyword to get the required id, then call the mutation tool with that id. Do not call a tool with empty parameters when required keys exist or when the user gave a specific query keyword."
            : "Rules: finish tasks end-to-end; if a tool can make progress output the XML tool_use tag; if ask_user is available and required info is missing, use ask_user XML; if ask_user is unavailable, explain the missing info in result; do not claim success before runtime observation; after a useful observation either call the next needed tool or output result only when the goal is complete; never output observation yourself; result content is inside <result>."
        let openAIWarning = isEvaluation
            ? "\nDo not copy focused tool lines into parameters or result. The content inside <tool_use> must be exactly one JSON object and nothing else. Never output <parameters>, <result> inside <tool_use>, <observation>, schema field names, placeholder IDs, JSON ReAct objects, markdown fences, Python dicts, OpenAI tool_call, args, arguments, input keys, or <think> text. The first bytes must be <thought>."
            : "\nDo not output OpenAI-style tool calls. Do not output {\"type\":\"tool_call\"}. Do not output function/args/arguments/input keys."
        return """
        \(contract)
        \(systemPrompt(for: profile))
        \(examples)\(rulesText)
        \(profileText)
        \(scopeText)\(openAIWarning)
        Available tool names: \(toolBlock)
        Focused tools: \(focusedToolBlock)
        Loaded context: \(contextBlock)
        Previous observations: \(traceBlock)
        Observation recovery tool catalog: \(observationRecoveryToolBlock)
        User goal: \(context.request.text)
        Input modalities: \(modalities.isEmpty ? "text" : modalities)
        Execution budget: iteration \(context.iteration), remaining tool calls \(context.remainingToolCalls), observation character cap \(context.maximumObservationCharacters)
        Current next-step instruction: \(nextStepDirective)
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

    private func nextStepDirective(for context: LuminaReActStepContext, isEvaluation: Bool) -> String {
        guard let lastObservation = context.trace.steps.last?.observation else {
            return "No runtime result yet. If a focused tool can progress the task, output tool_use now."
        }
        let goal = context.request.text
        let recentIDHint = recentIdentifierHint(in: context.trace)
        if lastObservation.replayed {
            return """
            The latest runtime result is a replay, so the identical tool_name + parameters has already been executed in this session.
            Use that observation as evidence. If the replayed observation is a successful terminal side effect and the user asked for only that operation, output result now. Otherwise continue with the next needed operation. If repeating the same operation is truly intentional, include a distinct idempotency_key or instance_id when the tool schema supports it.
            \(recentIDHint)
            """
        }
        switch lastObservation.status {
        case .succeeded:
            if isEvaluation && isTerminalSideEffectTool(lastObservation.toolName) {
                return """
                The latest runtime result succeeded for a write/open/send/update/delete/create/share operation. If that satisfies the full user goal, the next step must be <result>; do not verify by repeating search/update/delete/create and do not call summary/text.summarize/answer/exact.name/summarize_* helper tools. Use only the latest observation when stating dates/ids/details. If another requested operation remains, call only that next distinct required tool.
                \(recentIDHint)
                """
            }
            if isEvaluation && isReadOnlyTool(lastObservation.toolName) && isReadOnlyAnswerGoal(goal) {
                return """
                The latest matching read-only tool succeeded. The next step must be <result> with a concise answer based only on this observation. Do not call summary/text.summarize/text.transform, answer tools, close tools, or repeat the same read unless the observation explicitly says the needed data is missing.
                \(recentIDHint)
                """
            }
            if lastObservation.toolName == "device.current_time" {
                if isCreateOrScheduleGoal(goal) {
                    return """
                    Current time has been observed. Use that observed date/time to call the create/schedule tool with concrete ISO-8601 fields and requires_confirmation=true; if required fields are still missing, output cannot_complete.
                    \(recentIDHint)
                    """
                }
                if isExistingObjectMutationGoal(goal) {
                    return """
                    Current time has been observed. Search/list the existing target item to obtain its id, then mutate by id; if no matching lookup tool exists, output cannot_complete.
                    \(recentIDHint)
                    """
                }
            }
            if isReadOnlyAnswerGoal(goal) {
                return """
                The latest runtime result may answer this read-only user goal. If it fully satisfies the request, output result in concise Markdown using only runtime-observed facts; otherwise call the next required listed read tool. Never call unlisted summarizer/answer/close tools.
                \(recentIDHint)
                """
            }
            if lastObservation.summary.contains("[id=") || lastObservation.summary.contains("identifier") {
                if goal.contains("删除") || goal.localizedCaseInsensitiveContains("delete") {
                    return """
                    The latest runtime result contains item identifiers. Use the exact id inside [id=...] from the observation as the required id for the matching delete tool. Do not call availability and do not copy schema text into parameters.
                    \(recentIDHint)
                    """
                }
                if goal.contains("改") || goal.contains("修改") || goal.localizedCaseInsensitiveContains("update") || goal.localizedCaseInsensitiveContains("change") {
                    return """
                    The latest runtime result contains item identifiers. Use the exact id inside [id=...] from the observation as the required id for the matching update tool, and include only changed fields. Do not call availability and do not copy schema text into parameters.
                    \(recentIDHint)
                    """
                }
            }
            return """
            Use the latest real runtime result now. If it satisfies the goal, output result using observation facts and actual executed parameters. If the task needs another operation, call the next required tool with valid parameters.
            \(recentIDHint)
            """
        case .failed, .denied, .cancelled:
            let failure = lastObservation.summary
            if failure.localizedCaseInsensitiveContains("tool is not registered") ||
                failure.localizedCaseInsensitiveContains("unknown tool") {
                return """
                Unknown Tool: \(lastObservation.toolName). The latest tool name is invalid or outside the current tool scope. Use the complete tool schema in Observation recovery tool catalog. You must choose only an exact tool name from that schema, and pass only parameters declared by that tool. Do not invent close/answer/summary/text.summarize/exact.name tools and do not switch to another domain such as reminder for a calendar task. Output cannot_complete only if no listed tool can perform the operation.
                \(recentIDHint)
                """
            }
            if isEvaluation {
                if failure.localizedCaseInsensitiveContains("missing required parameter") ||
                    failure.localizedCaseInsensitiveContains("schema") {
                    return """
                    Value Error. \(lastObservation.toolName) parameters are available in Observation recovery tool catalog. Fill missing or invalid parameters from the user goal and previous observations, then retry \(lastObservation.toolName) with exactly the listed JSON parameter names and types. Only output cannot_complete when the needed value cannot be inferred from the user request or observations.
                    \(recentIDHint)
                    """
                }
                if lastObservation.status == .denied || lastObservation.status == .cancelled ||
                    failure.localizedCaseInsensitiveContains("permission") ||
                    failure.contains("权限") ||
                    failure.localizedCaseInsensitiveContains("cancelled") {
                    return """
                    The latest runtime result is not retryable in evaluation: permission/cancelled failures must not repeat the same tool call. Output cannot_complete, or call a different valid tool only if it can recover without repeating the failed parameters.
                    \(recentIDHint)
                    """
                }
            }
            if failure.localizedCaseInsensitiveContains("missing required parameter id") {
                return """
                The latest tool failed because id was missing. If a previous search/list observation contains an item like [id=...], call the intended update/delete/complete tool with that exact id. Do not repeat the same invalid parameters.
                \(recentIDHint)
                """
            }
            if failure.contains("在过去") || failure.localizedCaseInsensitiveContains("past") {
                return """
                The latest write failed because the date was in the past. Use the observed device.current_time output fields currentDateISO/iso8601 and timeZone/timeZoneIdentifier in Previous observations to recompute a future ISO-8601 date. If you cannot compute it, output cannot_complete.
                \(recentIDHint)
                """
            }
            return """
            The latest runtime result did not complete the task. Do not blindly retry the same tool_name + parameters. Correct the parameters, call a different valid recovery tool, or output cannot_complete/result with the recoverable reason.
            \(recentIDHint)
            """
        }
    }

    private func recentIdentifierHint(in trace: LuminaReActTrace) -> String {
        let summaries = trace.steps.compactMap(\.observation).suffix(4).map(\.summary)
        let joined = summaries.joined(separator: "\n")
        guard joined.contains("[id=") || joined.contains("identifier") else { return "" }
        return "Identifier rule: when an observation contains `[id=VALUE]`, copy VALUE exactly as the `id` parameter. Never output `_lumina_unparsed_parameters`, schema descriptions, or placeholder names as parameters."
    }

    private func isReadOnlyAnswerGoal(_ goal: String) -> Bool {
        let readOnlyTerms = ["查", "查看", "查询", "有没有", "有空", "列出", "读取", "总结", "整理成一句", "现在几点"]
        let writeTerms = ["创建", "新增", "保存", "写入", "改", "修改", "删除", "完成", "打开", "发送", "拨打", "复制"]
        return readOnlyTerms.contains(where: { goal.contains($0) }) &&
            !writeTerms.contains(where: { goal.contains($0) })
    }

    private func isCreateOrScheduleGoal(_ goal: String) -> Bool {
        ["创建", "新增", "安排", "提醒我", "叫我", "通知", "定一个"].contains(where: { goal.contains($0) }) &&
            !isExistingObjectMutationGoal(goal)
    }

    private func isExistingObjectMutationGoal(_ goal: String) -> Bool {
        ["改", "修改", "删除", "取消", "完成", "打开"].contains(where: { goal.contains($0) }) ||
            ["update", "delete", "complete", "open", "change"].contains { goal.localizedCaseInsensitiveContains($0) }
    }

    private func isTerminalSideEffectTool(_ toolName: String) -> Bool {
        [
            "calendar.create", "calendar.update", "calendar.delete",
            "reminder.create", "reminder.update", "reminder.complete", "reminder.delete",
            "contacts.create", "contacts.update", "contacts.open",
            "notification.schedule", "clipboard.write",
            "file.save_note", "file.update_note", "file.delete_note",
            "ledger.record", "ledger.update", "ledger.delete",
            "subscription.add", "subscription.remove",
            "maps.route", "app.open_settings", "share.prepare",
            "message.compose", "email.compose", "phone.call"
        ].contains(toolName)
    }

    private func isReadOnlyTool(_ toolName: String) -> Bool {
        !isTerminalSideEffectTool(toolName)
    }

    private func evaluationScopeInstructions(
        metadata: [String: LuminaJSONValue],
        tools: [LuminaToolSchema],
        isEvaluation: Bool
    ) -> String {
        guard isEvaluation else { return "" }
        let scope = metadata.string("lumina.evaluation.tool_scope") ?? "unspecified"
        let names = tools.map(\.name).sorted()
        let allowed = names.joined(separator: "; ")
        let prefixes = Set(names.compactMap { $0.split(separator: ".").first.map(String.init) })
            .sorted()
            .joined(separator: ", ")
        return """
        Evaluation tool scope: \(scope).
        Valid tool names for this task are exactly: \(allowed.isEmpty ? "none" : allowed).
        Valid tool prefixes: \(prefixes.isEmpty ? "none" : prefixes).
        Never call a tool name that is not in Valid tool names. Never switch domains: calendar tasks use calendar.* only, reminder tasks use reminder.* only, except device.current_time when it is listed. If no listed tool can finish the task, output <cannot_complete>.
        """
    }

    private func profileInstructions(for profile: LuminaAppPromptProfile, metadata: [String: LuminaJSONValue], isEvaluation: Bool) -> String {
        switch profile {
        case .taskExecution:
            if isEvaluation {
                return """
                Policy:
                - Relative time -> device.current_time first; do not invent calendar dates for today/tomorrow/next morning/minutes later.
                - Runtime Observation is authoritative. If it reports actual executed parameters, final result must use those actual parameters, not earlier model-proposed parameters.
                - writes/open/send -> requires_confirmation=true.
                - For create/new tasks, prefer the create tool after required fields are known; search first only when lookup/deduplication is part of the user goal.
                - When a search tool has query and the user supplied a title/name/keyword, set query to the most specific keyword. Do not use {} for targeted search.
                - Updating/deleting/completing existing calendar/reminder/contact/file/ledger/subscription objects requires search/list first to obtain id.
                - Adding or changing a contact email/phone uses contacts.search then contacts.update; if communication compose/call tools are unavailable, use cannot_complete instead of inventing one.
                - Completing/deleting a reminder uses reminder.search then reminder.complete/reminder.delete; creating a new reminder uses reminder.create.
                - memory/ask_user disabled.
                """
            }
            let memoryPolicy = memoryAccessDisabled(in: metadata) ? """
            - Memory disabled; do not use memory tools.
            """ : """
            - Save durable memory only via memory.ingest_text when the user asks or a stable reusable fact/preference appears; do not save transient state.
            """
            let askUserPolicy = askUserDisabled(in: metadata) ? """
            - ask_user disabled for this evaluation run; do not ask follow-up questions. If required information is missing and no safe default exists, use cannot_complete.
            """ : """
            - ask_user may be used when required details are missing and no safe default exists.
            """
            return """
            Task policy:
            - Relative date/time needs device.current_time first.
            - Side-effect tools may require confirmation; set requires_confirmation=true when writing/opening/sending.
            - If runtime returns a replayed observation, the identical tool_name + parameters already ran in this session; continue from that observation. To intentionally create another identical object, include a distinct idempotency_key or instance_id when supported.
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

    private func formatExamples(for profile: LuminaAppPromptProfile, tools: [LuminaToolSchema], isEvaluation: Bool) -> String {
        let names = Set(tools.map(\.name))
        var examples: [String] = []
        let reminderEight = Self.exampleTomorrowISO(hour: 8, minute: 0)
        let calendarSeven = Self.exampleTomorrowISO(hour: 7, minute: 0)
        let calendarSevenThirty = Self.exampleTomorrowISO(hour: 7, minute: 30)
        let reminderEightThirty = Self.exampleTomorrowISO(hour: 8, minute: 30)
        if names.contains("device.current_time") {
            examples.append("""
            Example no observation:
            User: 现在几点？
            Valid output exactly: <thought>Need current device time.</thought><tool_use name="device.current_time" requires_confirmation="false">{}</tool_use>
            Invalid: {"type":"result","content":"device.current_time|r|l|{}"}
            Example after observation:
            Runtime observation JSON: {"toolName":"device.current_time","status":"succeeded","replayed":false,"summary":"已读取本机时间：2026-05-25 21:51:48 Asia/Shanghai"}
            Valid output exactly: <thought>Time was observed.</thought><result>现在是 2026-05-25 21:51:48，时区 Asia/Shanghai。</result>
            """)
        }
        if isEvaluation, names.contains("device.current_time"), names.contains("reminder.create") {
            examples.append("""
            Example relative-time write:
            User: 明天早上 8 点提醒我带伞
            Valid output exactly: <thought>Tomorrow is relative; get current time first.</thought><tool_use name="device.current_time" requires_confirmation="false">{}</tool_use>
            After time observation:
            Valid output exactly: <thought>Create the reminder using an ISO due date from observed time.</thought><tool_use name="reminder.create" requires_confirmation="true">{"title":"带伞","dueDateISO":"\(reminderEight)"}</tool_use>
            Invalid for create: {"type":"tool_use","tool_name":"reminder.search","parameters":{"query":"带伞"}}
            """)
        }
        if isEvaluation, names.contains("device.current_time"), names.contains("calendar.create") {
            examples.append("""
            Example calendar create:
            User: 明天上午 7 点创建日程 清澜晨会
            Valid output exactly: <thought>Tomorrow is relative; get current time first.</thought><tool_use name="device.current_time" requires_confirmation="false">{}</tool_use>
            After time runtime result:
            Valid output exactly: <thought>Create a calendar event, not a reminder, because the user said 日程.</thought><tool_use name="calendar.create" requires_confirmation="true">{"title":"清澜晨会","startDateISO":"\(calendarSeven)","endDateISO":"\(calendarSevenThirty)"}</tool_use>
            Invalid for 日程: {"type":"tool_use","tool_name":"reminder.create","parameters":{"title":"清澜晨会"}}
            """)
        }
        if isEvaluation, names.contains("calendar.search"), names.contains("calendar.update") {
            examples.append("""
            Example calendar update:
            User: 把清澜明天 7 点的日程改成 7 点半
            Valid output exactly: <thought>Need the existing calendar event id before updating.</thought><tool_use name="calendar.search" requires_confirmation="false">{"query":"清澜"}</tool_use>
            After search runtime result containing [id=cal-qinglan-001]:
            Valid output exactly: <thought>Update the found calendar event by id.</thought><tool_use name="calendar.update" requires_confirmation="true">{"id":"cal-qinglan-001","startDateISO":"\(calendarSevenThirty)"}</tool_use>
            Invalid for 日程: {"type":"tool_use","tool_name":"reminder.search","parameters":{"query":"清澜"}}
            """)
        }
        if isEvaluation, names.contains("calendar.search"), names.contains("calendar.delete") {
            examples.append("""
            Example calendar delete:
            User: 删除清澜日程
            Valid output exactly: <thought>Need the calendar event id before deleting.</thought><tool_use name="calendar.search" requires_confirmation="false">{"query":"清澜"}</tool_use>
            After search runtime result containing [id=cal-qinglan-001]:
            Valid output exactly: <thought>Delete the found calendar event by id.</thought><tool_use name="calendar.delete" requires_confirmation="true">{"id":"cal-qinglan-001"}</tool_use>
            """)
        }
        if isEvaluation, names.contains("reminder.search"), names.contains("reminder.update") {
            examples.append("""
            Example update existing item:
            User: 把带伞提醒改到明早 8 点半
            Valid output exactly: <thought>Need the existing reminder id before updating.</thought><tool_use name="reminder.search" requires_confirmation="false">{"query":"带伞"}</tool_use>
            After search observation containing [id=rem-umbrella-001]:
            Valid output exactly: <thought>Update the found reminder by id.</thought><tool_use name="reminder.update" requires_confirmation="true">{"id":"rem-umbrella-001","dueDateISO":"\(reminderEightThirty)"}</tool_use>
            """)
        }
        if !isEvaluation, profile == .taskExecution, names.contains("ask_user") {
            examples.append("""
            Example missing required info:
            User: 帮我安排一下
            Valid output exactly: <thought>Need user preference before continuing.</thought><ask_user>{"reason":"缺少安排偏好","questions":[{"id":"preference","question":"你想优先安排哪类事情？","options":[{"label":"工作","description":"优先整理工作任务"},{"label":"生活","description":"优先整理生活事项"}]}],"sensitivity":"normal","timeout_seconds":120,"allow_custom_answer":true}</ask_user>
            """)
        }
        guard !examples.isEmpty else { return "Examples: none" }
        return "Format few-shot examples:\n" + examples.joined(separator: "\n")
    }

    private static func exampleTomorrowISO(hour: Int, minute: Int) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        var components = calendar.dateComponents([.year, .month, .day], from: Date().addingTimeInterval(86_400))
        components.hour = hour
        components.minute = minute
        components.second = 0
        let date = calendar.date(from: components) ?? Date().addingTimeInterval(86_400)
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
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

    private func compactToolNameContext(for schemas: [LuminaToolSchema], isEvaluation: Bool) -> String {
        schemas
            .filter { !(isEvaluation && $0.name == "ask_user") }
            .sorted { $0.name < $1.name }.map { schema in
            schema.name
        }.joined(separator: "; ")
    }

    private func focusedToolContext(for context: LuminaReActStepContext, isEvaluation: Bool) -> String {
        let selected = focusedTools(
            for: context.request.text,
            schemas: context.availableTools,
            profile: promptProfile(from: context.request.metadata),
            trace: context.trace,
            isEvaluation: isEvaluation,
            limit: isEvaluation ? 5 : maximumFocusedToolDetails
        )
        guard !selected.isEmpty else { return "none" }
        if isEvaluation {
            return selected.map(evaluationToolSchemaLine(for:)).joined(separator: "\n")
        }
        let objects = selected.map { schema in
            let required = schema.parameters.filter(\.required).map(\.name)
            return [
                "name": schema.name,
                "description": schema.description.truncated(to: 120),
                "side_effect": schema.sideEffect == .readOnly ? "read_only" : "writes_or_opens",
                "sensitivity": schema.sensitivity.rawValue,
                "requires_confirmation": schema.sideEffect != .readOnly,
                "required_parameters": required,
                "parameters": schema.parameters.map { parameter in
                    [
                        "name": parameter.name,
                        "type": parameter.type.rawValue,
                        "required": parameter.required,
                        "description": parameter.description.truncated(to: 80)
                    ] as [String: Any]
                }
            ] as [String: Any]
        }
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return selected.map(\.name).joined(separator: ", ")
        }
        return json
    }

    private func observationRecoveryToolContext(for context: LuminaReActStepContext, isEvaluation: Bool) -> String {
        guard let observation = context.trace.steps.last?.observation else { return "none" }
        guard observation.status == .failed || observation.status == .denied || observation.status == .cancelled else {
            return "none"
        }

        let failureText = [observation.summary, observation.errorMessage ?? ""]
            .joined(separator: "\n")
            .lowercased()
        let visibleTools = context.availableTools
            .filter { !(isEvaluation && $0.name == "ask_user") }
            .sorted { $0.name < $1.name }

        if failureText.contains("tool is not registered") ||
            failureText.contains("unknown tool") ||
            failureText.contains("unregistered tool") {
            return """
            Unknown Tool: \(observation.toolName).
            All available tools:
            \(fullToolCatalogJSON(for: visibleTools))
            You must choose only an exact tool name from the schema above, with only the listed parameter names and JSON types.
            """
        }

        if failureText.contains("missing required parameter") ||
            failureText.contains("invalid type") ||
            failureText.contains("allowed enum") ||
            failureText.contains("parameters must be a json object") ||
            failureText.contains("schema") {
            if let schema = visibleTools.first(where: { $0.name == observation.toolName }) {
                return """
                Value Error. \(observation.toolName) parameters are:
                \(fullToolCatalogJSON(for: [schema]))
                Fill missing or invalid parameters from the user request and previous observations, then retry with exactly the parameter names and JSON types shown above. Only output cannot_complete when the needed value cannot be inferred.
                """
            }
            return """
            Value Error. \(observation.toolName) parameters are:
            \(fullToolCatalogJSON(for: visibleTools))
            Fill missing or invalid parameters from the user request and previous observations, then retry with exactly the parameter names and JSON types shown above. Only output cannot_complete when the needed value cannot be inferred.
            """
        }

        return "none"
    }

    private func fullToolCatalogJSON(for schemas: [LuminaToolSchema]) -> String {
        let objects = fullToolCatalogObjects(for: schemas)
        guard JSONSerialization.isValidJSONObject(objects),
              let data = try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return schemas.map { schema in
                let parameters = schema.parameters
                    .sorted { $0.name < $1.name }
                    .map { "\($0.name):\($0.type.rawValue):\($0.required ? "required" : "optional"):\($0.description)" }
                    .joined(separator: " | ")
                return "\(schema.name): \(schema.description); parameters \(parameters.isEmpty ? "none" : parameters)"
            }.joined(separator: "\n")
        }
        return json
    }

    private func fullToolCatalogObjects(for schemas: [LuminaToolSchema]) -> [[String: Any]] {
        schemas.map { schema in
            [
                "name": schema.name,
                "description": schema.description,
                "side_effect": schema.sideEffect.rawValue,
                "sensitivity": schema.sensitivity.rawValue,
                "requires_confirmation": schema.sideEffect != .readOnly,
                "parameters": schema.parameters
                    .sorted { $0.name < $1.name }
                    .map { parameter in
                        [
                            "name": parameter.name,
                            "type": parameter.type.rawValue,
                            "required": parameter.required,
                            "description": parameter.description,
                            "sensitive": parameter.sensitive
                        ] as [String: Any]
                    }
            ] as [String: Any]
        }
    }

    private func evaluationToolSchemaLine(for schema: LuminaToolSchema) -> String {
        let sideEffect = schema.sideEffect == .readOnly ? "read" : "write"
        let parameterText = schema.parameters.isEmpty
            ? "parameters none"
            : "parameters " + schema.parameters
                .sorted { $0.name < $1.name }
                .map { parameter in
                    let requirement = parameter.required ? "required" : "optional"
                    let description = parameter.description.truncated(to: 72)
                    return "\(parameter.name):\(parameter.type.rawValue):\(requirement):\(description)"
                }
                .joined(separator: " | ")
        return "\(schema.name): \(sideEffect) tool; \(parameterText); output exactly one JSON object using these parameter names inside <tool_use>."
    }

    private func callTemplate(for schema: LuminaToolSchema) -> [String: Any] {
        [
            "schema_version": "1.0",
            "step_id": "s-tool",
            "type": "tool_use",
            "thought": "why this tool is needed",
            "tool_name": schema.name,
            "parameters": Dictionary(uniqueKeysWithValues: schema.parameters.map { parameter in
                (parameter.name, placeholder(for: parameter))
            }),
            "requires_confirmation": schema.sideEffect != .readOnly
        ]
    }

    private func xmlCallTemplate(for schema: LuminaToolSchema) -> String {
        let parameters = Dictionary(uniqueKeysWithValues: schema.parameters.map { parameter in
            (parameter.name, placeholder(for: parameter))
        })
        let parameterJSON: String
        if JSONSerialization.isValidJSONObject(parameters),
           let data = try? JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            parameterJSON = json
        } else {
            parameterJSON = "{}"
        }
        let confirmation = schema.sideEffect == .readOnly ? "false" : "true"
        return #"<thought>why this tool is needed</thought><tool_use name="\#(schema.name)" requires_confirmation="\#(confirmation)">\#(parameterJSON)</tool_use>"#
    }

    private func placeholder(for parameter: LuminaToolParameterSchema) -> Any {
        switch parameter.type {
        case .string:
            if parameter.name == "query" {
                return "keyword from user request"
            }
            if parameter.name == "id" || parameter.name == "identifier" {
                return "id from runtime result"
            }
            return parameter.required ? "REQUIRED_STRING" : "optional string"
        case .number:
            return 0
        case .bool:
            return false
        case .dateISO8601:
            return "YYYY-MM-DDTHH:mm:ssZZZZZ"
        case .object:
            return [:] as [String: Any]
        case .array:
            return [] as [Any]
        }
    }

    private func focusedTools(
        for request: String,
        schemas: [LuminaToolSchema],
        profile: LuminaAppPromptProfile,
        trace: LuminaReActTrace,
        isEvaluation: Bool,
        limit: Int
    ) -> [LuminaToolSchema] {
        let query = request.lowercased()
        let currentTimeAlreadyObserved = trace.observations.contains {
            $0.toolName == "device.current_time" && $0.status == .succeeded
        }
        let alwaysUseful: Set<String>
        if profile == .homePersonalization {
            alwaysUseful = ["device.current_time", "memory.stats", "memory.recent"]
        } else if isEvaluation {
            alwaysUseful = currentTimeAlreadyObserved ? [] : ["device.current_time"]
        } else {
            alwaysUseful = ["ask_user", "device.current_time"]
        }
        let scored = schemas.map { schema in
            (schema, focusScore(schema: schema, query: query, alwaysUseful: alwaysUseful))
        }
        .filter { $0.1 > 0 }
        .sorted {
            if $0.1 == $1.1 { return $0.0.name < $1.0.name }
            return $0.1 > $1.1
        }
        let selected = Array(scored.prefix(limit).map(\.0))
        var focused = addLookupPrerequisites(to: selected, from: schemas, limit: limit)
        if isEvaluation && currentTimeAlreadyObserved {
            focused.removeAll { $0.name == "device.current_time" }
        }
        return focused
    }

    private func addLookupPrerequisites(
        to selected: [LuminaToolSchema],
        from schemas: [LuminaToolSchema],
        limit: Int
    ) -> [LuminaToolSchema] {
        var result = selected
        let selectedNames = Set(selected.map(\.name))
        let schemasByName = Dictionary(uniqueKeysWithValues: schemas.map { ($0.name, $0) })
        let prerequisitePairs: [(String, String)] = [
            ("calendar.update", "calendar.search"),
            ("calendar.delete", "calendar.search"),
            ("calendar.create", "device.current_time"),
            ("reminder.update", "reminder.search"),
            ("reminder.complete", "reminder.search"),
            ("reminder.delete", "reminder.search"),
            ("reminder.create", "device.current_time"),
            ("notification.schedule", "device.current_time"),
            ("contacts.update", "contacts.search"),
            ("contacts.open", "contacts.search"),
            ("ledger.update", "ledger.search"),
            ("ledger.delete", "ledger.search"),
            ("subscription.remove", "subscription.list"),
            ("file.read_note", "file.list_notes"),
            ("file.update_note", "file.list_notes"),
            ("file.delete_note", "file.list_notes")
        ]
        for (tool, prerequisite) in prerequisitePairs where selectedNames.contains(tool) {
            guard !result.contains(where: { $0.name == prerequisite }),
                  let schema = schemasByName[prerequisite] else {
                continue
            }
            result.insert(schema, at: 0)
        }
        return Array(result.prefix(max(limit, result.count)))
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

    private func compactTraceContext(
        _ trace: LuminaReActTrace,
        visibleTools: [LuminaToolSchema],
        isEvaluation: Bool
    ) throws -> String {
        let stepLimit = isEvaluation ? max(6, maximumTraceObservations * 2) : maximumTraceObservations * 2
        let compactSteps = trace.steps.suffix(stepLimit)
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
                var object: [String: Any] = [
                    "toolName": observation.toolName,
                    "status": observation.status.rawValue,
                    "replayed": observation.replayed,
                    "summary": observation.summary.truncated(to: isEvaluation ? 360 : 240)
                ]
                if !observation.output.isEmpty {
                    object["output"] = observation.output.compactModelTraceValue.truncated(to: isEvaluation ? 700 : 520)
                }
                if let error = observation.errorMessage, !error.isEmpty {
                    object["error"] = error.truncated(to: 120)
                }
                if let recovery = observationRecoveryPayload(
                    for: observation,
                    visibleTools: visibleTools,
                    isEvaluation: isEvaluation
                ) {
                    object["recovery"] = recovery
                }
                guard JSONSerialization.isValidJSONObject(object),
                      let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
                      let json = String(data: data, encoding: .utf8) else {
                    return "Runtime observation summary: \(observation.summary.truncated(to: 240))"
                }
                return "Runtime observation JSON: \(json)"
            case .result:
                guard let final = step.resultMarkdown else { return nil }
                return "Result(model): \(final.truncated(to: 180))"
            }
        }
        let text = lines.joined(separator: "\n")
        return text.isEmpty ? "none" : text.truncated(to: isEvaluation ? 3_000 : maximumTraceCharacters)
    }

    private func observationRecoveryPayload(
        for observation: LuminaReActObservation,
        visibleTools: [LuminaToolSchema],
        isEvaluation: Bool
    ) -> [String: Any]? {
        guard observation.status == .failed || observation.status == .denied || observation.status == .cancelled else {
            return nil
        }

        let failureText = [observation.summary, observation.errorMessage ?? ""]
            .joined(separator: "\n")
            .lowercased()
        let tools = visibleTools
            .filter { !(isEvaluation && $0.name == "ask_user") }
            .sorted { $0.name < $1.name }

        if failureText.contains("tool is not registered") ||
            failureText.contains("unknown tool") ||
            failureText.contains("unregistered tool") {
            return [
                "reason": "unknown_tool",
                "instruction": "Unknown Tool: \(observation.toolName). Choose only an exact tool name from availableTools and pass only parameters declared by that schema. Do not invent summary, text.summarize, answer, exact.name, close, or helper tools.",
                "availableToolNames": tools.map(\.name),
                "availableTools": fullToolCatalogObjects(for: tools)
            ]
        }

        if failureText.contains("missing required parameter") ||
            failureText.contains("invalid type") ||
            failureText.contains("allowed enum") ||
            failureText.contains("parameters must be a json object") ||
            failureText.contains("schema") {
            let schemas = tools.first(where: { $0.name == observation.toolName }).map { [$0] } ?? tools
            return [
                "reason": "invalid_tool_parameters",
                "instruction": "Value Error. \(observation.toolName) parameters are listed in availableTools. Fill missing or invalid parameters from the user request and previous observations, retry with exactly those parameter names and valid JSON types, and output cannot_complete only when the needed value cannot be inferred.",
                "availableToolNames": tools.map(\.name),
                "availableTools": fullToolCatalogObjects(for: schemas)
            ]
        }

        return nil
    }
}
