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
        let traceBlock = try compactTraceContext(context.trace, isEvaluation: isEvaluation)
        let contextBlock = loadedContextBlock(context.loadedContext, isEvaluation: isEvaluation)
        let hasRuntimeObservation = context.trace.steps.contains { $0.kind == .observation }
        let modalities = context.request.content.modalities.map(\.rawValue).sorted().joined(separator: ", ")
        let contract = isEvaluation
            ? #"FIRST BYTES MUST BE <thought>. Output exactly one valid Lumina XML ReAct step and nothing else. No <think>, prose, markdown, fences, JSON ReAct object, labels, schema text, or tool_call blocks. Tool step shape: <thought>why</thought><tool_use name="exact.name" requires_confirmation="false">{}</tool_use>. Answer shape: <thought>done</thought><result>markdown answer</result>. Blocker shape: <thought>blocked</thought><cannot_complete>reason</cannot_complete>. In evaluation, ask_user is unavailable; use <cannot_complete> when required information is missing. Before any runtime result, if a tool can progress the task, call the tool; do not output result. After a successful runtime result, the default next step is <result>; call another tool only when a different required tool is still needed. Never repeat read/search/list/current_time/location/clipboard/document tools after a successful observation. If a runtime result failed from permission, cancellation, schema, missing parameters, or repeated identical call, do not retry the same call; use cannot_complete or a different valid tool."#
            : LuminaReActSchema.compactPromptContract
        let examples = (hasRuntimeObservation && !isEvaluation) ? "" : "\(formatExamples(for: profile, tools: context.availableTools, isEvaluation: isEvaluation))\n"
        let profileText = profileInstructions(for: profile, metadata: context.request.metadata, isEvaluation: isEvaluation)
        let nextStepDirective = nextStepDirective(for: context, isEvaluation: isEvaluation)
        let rulesText = isEvaluation
            ? "Use tools to progress. If focused tools contain a relevant tool, call it with the XML tool_use tag. Do not claim success before a real runtime Observation. After any successful Observation, stop with result unless a different required tool remains. For create/new calendar or reminder tasks with relative time, call device.current_time only when no current-time observation exists; once time is observed, create the item or finish. For update/delete/complete/open tasks that identify an item by title or name, first call the matching search/list tool with a query keyword to get the required id, then call the mutation tool with that id. Never call a tool with empty parameters when required keys exist or when the user gave a specific query keyword."
            : "Rules: finish tasks end-to-end; if a tool can make progress output the XML tool_use tag; if ask_user is available and required info is missing, use ask_user XML; if ask_user is unavailable, explain the missing info in result; never claim success before runtime observation; after a useful observation either call the next needed tool or output result; never output observation yourself; result content is inside <result>."
        let openAIWarning = isEvaluation
            ? "\nDo not copy focused tool lines into parameters or result. The content inside <tool_use> must be exactly one JSON object and nothing else. Never output <parameters>, <result> inside <tool_use>, <observation>, schema field names, placeholder IDs, JSON ReAct objects, markdown fences, Python dicts, OpenAI tool_call, args, arguments, input keys, or <think> text. The first bytes must be <thought>."
            : "\nDo not output OpenAI-style tool calls. Do not output {\"type\":\"tool_call\"}. Do not output function/args/arguments/input keys."
        return """
        \(contract)
        \(systemPrompt(for: profile))
        \(examples)\(rulesText)
        \(profileText)\(openAIWarning)
        Available tool names: \(toolBlock)
        Focused tools: \(focusedToolBlock)
        Loaded context: \(contextBlock)
        Previous observations: \(traceBlock)
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
            Do not call that identical tool again. Output result if that result completes the user goal; otherwise call a different needed tool with valid parameters or cannot_complete.
            \(recentIDHint)
            """
        }
        switch lastObservation.status {
        case .succeeded:
            if isEvaluation && isTerminalSideEffectTool(lastObservation.toolName) {
                return """
                The latest runtime result succeeded for a write/open/send/update/delete/create operation. Do not call another read/search/current_time tool. Output result now, concisely confirming completion from the latest observation.
                \(recentIDHint)
                """
            }
            if lastObservation.toolName == "device.current_time" {
                if isCreateOrScheduleGoal(goal) {
                    return """
                    Current time has already been observed. Do not call device.current_time again. Use that observed date/time to call the create/schedule tool now with concrete ISO-8601 fields and requires_confirmation=true; if required fields are still missing, output cannot_complete.
                    \(recentIDHint)
                    """
                }
                if isExistingObjectMutationGoal(goal) {
                    return """
                    Current time has already been observed. Do not call device.current_time again. Search/list the existing target item now to obtain its id, then mutate by id; if no matching lookup tool exists, output cannot_complete.
                    \(recentIDHint)
                    """
                }
            }
            if isReadOnlyAnswerGoal(goal) {
                return """
                The latest runtime result is the answer data for this read-only user goal. Do not call another tool. Output result in concise Markdown using only this runtime result.
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
            Use the latest real runtime result now. If it satisfies the goal, output a result object. If the task needs another operation, call the next different tool with required parameters.
            \(recentIDHint)
            """
        case .failed, .denied, .cancelled:
            let failure = lastObservation.summary
            if isEvaluation {
                if lastObservation.status == .denied || lastObservation.status == .cancelled ||
                    failure.localizedCaseInsensitiveContains("permission") ||
                    failure.contains("权限") ||
                    failure.localizedCaseInsensitiveContains("missing required parameter") ||
                    failure.localizedCaseInsensitiveContains("schema") {
                    return """
                    The latest runtime result is not retryable in evaluation: permission/cancelled/schema/missing-parameter failures must not repeat the same tool call. Output cannot_complete, or call a different valid tool only if it can recover without repeating the failed parameters.
                    \(recentIDHint)
                    """
                }
            }
            if failure.localizedCaseInsensitiveContains("missing required parameter id") {
                return """
                The latest tool failed because id was missing. If a previous search/list observation contains an item like [id=...], call the intended update/delete/complete tool with that exact id. Do not call availability and do not repeat the same invalid parameters.
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
            The latest runtime result did not complete the task. Do not blindly retry the same tool_name + parameters. Output cannot_complete or result with the recoverable reason, retry once only if the error is clearly transient, or call a different valid tool if one can recover.
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

    private func profileInstructions(for profile: LuminaAppPromptProfile, metadata: [String: LuminaJSONValue], isEvaluation: Bool) -> String {
        switch profile {
        case .taskExecution:
            if isEvaluation {
                return """
                Policy:
                - Relative time -> device.current_time first; never invent calendar dates for today/tomorrow/next morning/minutes later.
                - writes/open/send -> requires_confirmation=true.
                - For create/new tasks, do not search first unless the user explicitly asks to avoid duplicates.
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
            - If runtime returns a replayed observation, the identical tool_name + parameters already ran in this session; continue from that observation instead of repeating it. To intentionally create another identical object, include a distinct idempotency_key or instance_id in parameters.
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
            Valid output exactly: <thought>Create the reminder using an ISO due date from observed time.</thought><tool_use name="reminder.create" requires_confirmation="true">{"title":"带伞","dueDateISO":"2026-05-29T08:00:00+08:00"}</tool_use>
            Invalid for create: {"type":"tool_use","tool_name":"reminder.search","parameters":{"query":"带伞"}}
            """)
        }
        if isEvaluation, names.contains("device.current_time"), names.contains("calendar.create") {
            examples.append("""
            Example calendar create:
            User: 明天上午 7 点创建日程 清澜晨会
            Valid output exactly: <thought>Tomorrow is relative; get current time first.</thought><tool_use name="device.current_time" requires_confirmation="false">{}</tool_use>
            After time runtime result:
            Valid output exactly: <thought>Create a calendar event, not a reminder, because the user said 日程.</thought><tool_use name="calendar.create" requires_confirmation="true">{"title":"清澜晨会","startDateISO":"2026-05-29T07:00:00+08:00","endDateISO":"2026-05-29T07:30:00+08:00"}</tool_use>
            Invalid for 日程: {"type":"tool_use","tool_name":"reminder.create","parameters":{"title":"清澜晨会"}}
            """)
        }
        if isEvaluation, names.contains("calendar.search"), names.contains("calendar.update") {
            examples.append("""
            Example calendar update:
            User: 把清澜明天 7 点的日程改成 7 点半
            Valid output exactly: <thought>Need the existing calendar event id before updating.</thought><tool_use name="calendar.search" requires_confirmation="false">{"query":"清澜"}</tool_use>
            After search runtime result containing [id=cal-qinglan-001]:
            Valid output exactly: <thought>Update the found calendar event by id.</thought><tool_use name="calendar.update" requires_confirmation="true">{"id":"cal-qinglan-001","startDateISO":"2026-05-29T07:30:00+08:00"}</tool_use>
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
            Valid output exactly: <thought>Update the found reminder by id.</thought><tool_use name="reminder.update" requires_confirmation="true">{"id":"rem-umbrella-001","dueDateISO":"2026-05-29T08:30:00+08:00"}</tool_use>
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

    private func evaluationToolSchemaLine(for schema: LuminaToolSchema) -> String {
        let required = schema.parameters.filter(\.required).map(\.name).sorted()
        let optional = schema.parameters.filter { !$0.required }.map(\.name).sorted()
        let sideEffect = schema.sideEffect == .readOnly ? "read" : "write"
        let requiredText = required.isEmpty ? "no required keys" : "required keys \(required.joined(separator: ","))"
        let optionalText = optional.isEmpty ? "no optional keys" : "optional keys \(optional.joined(separator: ","))"
        return "\(schema.name): \(sideEffect) tool; \(requiredText); \(optionalText); output only the JSON object inside <tool_use>."
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
                var object: [String: Any] = [
                    "toolName": observation.toolName,
                    "status": observation.status.rawValue,
                    "replayed": observation.replayed,
                    "summary": observation.summary.truncated(to: 240)
                ]
                if !observation.output.isEmpty {
                    object["output"] = observation.output.compactModelTraceValue.truncated(to: isEvaluation ? 360 : 520)
                }
                if let error = observation.errorMessage, !error.isEmpty {
                    object["error"] = error.truncated(to: 120)
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
        return text.isEmpty ? "none" : text.truncated(to: isEvaluation ? 420 : maximumTraceCharacters)
    }
}
