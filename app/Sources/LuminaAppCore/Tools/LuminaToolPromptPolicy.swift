import Foundation
import LuminaAgentRuntime

/// Prompt disclosure is a relevance hint; Runtime still owns validation and permissions.
public enum LuminaToolPromptPolicy {
    public static func focusedTools(request: String, schemas: [LuminaToolSchema], trace: LuminaReActTrace = .init(), limit: Int = 8) -> [LuminaToolSchema] {
        let query = request.lowercased()
        let sorted = schemas.sorted { $0.name < $1.name }
        var scored: [(LuminaToolSchema, Int)] = []
        for schema in sorted {
            let relevance = score(schema, query: query)
            if relevance > 0 { scored.append((schema, relevance)) }
        }
        scored.sort { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.name < rhs.0.name }
            return lhs.1 > rhs.1
        }
        // An unknown domain must not lose access to its schemas.
        guard !scored.isEmpty else { return sorted }
        var selected = Array(scored.prefix(max(1, limit)).map { $0.0 })
        // Keep the best match of every requested domain for compound requests.
        var domains = Set(selected.map { domain($0.name) })
        for (schema, _) in scored where domains.insert(domain(schema.name)).inserted {
            selected.append(schema)
        }
        var required = Set<String>()
        for schema in selected {
            if let prerequisite = prerequisites[schema.name] { required.insert(prerequisite) }
        }
        if requiresCurrentTime(request) && !trace.observations.contains(where: { $0.toolName == "device.current_time" && $0.status == .succeeded }) {
            required.insert("device.current_time")
        }
        if let last = trace.observations.last, last.status != .succeeded {
            required.insert(last.toolName)
            if case let .object(failure)? = last.output["failure"],
               case let .object(call)? = failure["suggestedCall"],
               case let .string(name)? = call["toolName"] ?? call["tool_name"] {
                required.insert(name)
            }
        }
        for schema in sorted where required.contains(schema.name) && !selected.contains(where: { $0.name == schema.name }) {
            selected.append(schema)
        }
        let pendingNames = pendingWriteFailures(request: request, schemas: schemas, trace: trace).map(\.toolName)
        if !pendingNames.isEmpty {
            let ranks = Dictionary(uniqueKeysWithValues: pendingNames.enumerated().map { ($0.element, $0.offset) })
            selected = selected.enumerated().sorted { lhs, rhs in
                let left = ranks[lhs.element.name] ?? (pendingNames.count + lhs.offset)
                let right = ranks[rhs.element.name] ?? (pendingNames.count + rhs.offset)
                return left < right
            }.map { $0.element }
        }
        return selected
    }

    public static func observationsWithArguments(_ trace: LuminaReActTrace) -> [(LuminaReActObservation, [String: LuminaJSONValue])] {
        var pending: [String: [[String: LuminaJSONValue]]] = [:]
        var records: [(LuminaReActObservation, [String: LuminaJSONValue])] = []
        for step in trace.steps {
            if let call = step.action { pending[call.toolName, default: []].append(call.arguments) }
            for call in step.toolCalls { pending[call.toolName, default: []].append(call.arguments) }
            if let observation = step.observation {
                let arguments = pending[observation.toolName]?.isEmpty == false
                    ? pending[observation.toolName]!.removeFirst() : [:]
                records.append((observation, arguments))
            }
        }
        return records
    }

    /// A suggestion is never executed here. It is formed only from a unique observed
    /// object and an explicitly resolved user target, not from guessed IDs or dates.
    public static func suggestedLookupMutation(request: String, schemas: [LuminaToolSchema], trace: LuminaReActTrace, timeHints: [LuminaJSONValue]) -> LuminaJSONValue? {
        let query = request.lowercased()
        guard ["修改", "改到", "改成", "改为", "调整", "推迟", "update", "reschedule"].contains(where: query.contains),
              let lookup = trace.observations.last(where: { $0.toolName == "calendar.search" && $0.status == .succeeded }),
              case let .array(items)? = lookup.output["items"], items.count == 1,
              case let .object(item) = items[0],
              case let .string(id)? = item["id"] ?? item["identifier"],
              let schema = schemas.first(where: { $0.name == "calendar.update" }) else { return nil }
        let targets = timeHints.compactMap { hint -> String? in
            guard case let .object(value) = hint, value["toolDomain"] == .string("calendar"),
                  case let .string(date)? = value["dateISO"] else { return nil }
            return date
        }
        guard targets.count == 1 else { return nil }
        var arguments: [String: LuminaJSONValue] = ["id": .string(id), "startDateISO": .string(targets[0])]
        if ["保持", "时长不变", "same duration", "keep"].contains(where: query.contains),
           let oldStart = item["startDateISO"]?.stringValue.flatMap(LuminaToolFailureFeedback.parseDate),
           let oldEnd = item["endDateISO"]?.stringValue.flatMap(LuminaToolFailureFeedback.parseDate), oldEnd > oldStart,
           let newStart = LuminaToolFailureFeedback.parseDate(targets[0]) {
            let formatter = ISO8601DateFormatter()
            if let timeZone = item["timeZone"]?.stringValue { formatter.timeZone = TimeZone(identifier: timeZone) }
            arguments["endDateISO"] = .string(formatter.string(from: newStart.addingTimeInterval(oldEnd.timeIntervalSince(oldStart))))
        }
        let names = Set(schema.parameters.map(\.name))
        guard arguments.keys.allSatisfy(names.contains), schema.parameters.filter(\.required).allSatisfy({ arguments[$0.name] != nil }) else { return nil }
        return .object(["toolName": .string(schema.name), "arguments": .object(arguments)])
    }

    /// Failed write attempts remain pending until that tool actually succeeds.
    /// A different successful tool does not make a failed operation complete.
    public static func pendingWriteFailures(request: String, schemas: [LuminaToolSchema], trace: LuminaReActTrace) -> [LuminaReActObservation] {
        let writes = Set(schemas.filter { $0.sideEffect != .readOnly }.map(\.name))
        var pending: [String: (Int, LuminaReActObservation)] = [:]
        for (index, pair) in observationsWithArguments(trace).enumerated() {
            let (observation, arguments) = pair
            guard writes.contains(observation.toolName) else { continue }
            if observation.status == .succeeded { pending.removeValue(forKey: observation.toolName) }
            else {
                pending[observation.toolName] = (index, LuminaToolFailureFeedback.enrichedObservation(
                    observation, arguments: arguments, availableTools: schemas, request: request, trace: trace
                ))
            }
        }
        return pending.values.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    public static func scheduleProgress(_ hints: [LuminaJSONValue], schemas: [LuminaToolSchema], trace: LuminaReActTrace) -> [LuminaJSONValue] {
        let writes = Set(schemas.filter { $0.sideEffect != .readOnly }.map(\.name))
        return hints.map { hint in
            guard case var .object(fields) = hint,
                  let domain = fields["toolDomain"]?.stringValue,
                  let iso = fields["dateISO"]?.stringValue,
                  let date = LuminaToolFailureFeedback.parseDate(iso),
                  let clause = fields["clause"]?.stringValue else { return hint }
            let matches = hints.filter { candidate in
                guard case let .object(other) = candidate else { return false }
                return other["toolDomain"] == fields["toolDomain"] && other["dateISO"] == fields["dateISO"]
            }
            guard matches.count == 1 else { return hint }
            let editing = ["修改", "改到", "改成", "改为", "调整", "推迟", "update", "reschedule"].contains { clause.lowercased().contains($0) }
            guard !["删除", "取消", "完成", "delete", "remove"].contains(where: clause.contains) else { return hint }
            let toolName = domain == "notification" ? "notification.schedule" : domain + (editing ? ".update" : ".create")
            guard writes.contains(toolName) else { return hint }
            let field = domain == "calendar" ? "startDateISO" : domain == "reminder" ? "dueDateISO" : "dateISO"
            let completed = trace.observations.contains { observation in
                guard observation.toolName == toolName, observation.status == .succeeded else { return false }
                var value = observation.output[field]?.stringValue
                if value == nil, domain == "notification" { value = observation.output["fireDate"]?.stringValue }
                if value == nil, case let .object(actual)? = observation.output["executedArguments"] { value = actual[field]?.stringValue }
                return value.flatMap(LuminaToolFailureFeedback.parseDate).map { abs($0.timeIntervalSince(date)) < 1 } ?? false
            }
            fields["toolName"] = .string(toolName)
            fields["executionStatus"] = .string(completed ? "completed" : "pending")
            return .object(fields)
        }
    }

    public static func requiresCurrentTime(_ request: String) -> Bool {
        let query = request.lowercased()
        return ["今天", "明天", "后天", "明早", "今晚", "稍后", "分钟后", "小时后", "下周", "下星期", "tomorrow", "today", "tonight", "next week", "minutes from now", "hours from now"].contains(where: query.contains)
    }

    public static let assistantGenerationPrefix = "<|im_start|>assistant\n<think>\n\n</think>\n\n"

    /// Mirrors tokenizer.chat_template in the bundled MiniCPM-V 4.6 GGUF.
    /// Tool results are user turns containing tool_response, not fresh user goals.
    public static func chatPrompt(system: String, user: String, observations: [LuminaJSONValue]) -> String {
        var prompt = "<|im_start|>system\n" + chatSafe(system) + "<|im_end|>\n"
        prompt += "<|im_start|>user\n" + chatSafe(user) + "<|im_end|>\n"
        for observation in observations {
            guard case let .object(record) = observation,
                  case let .string(name)? = record["tool_name"] else { continue }
            let arguments: [String: LuminaJSONValue]
            if case let .object(values)? = record["arguments"] { arguments = values } else { arguments = [:] }
            let parameters = arguments.keys.sorted().map { key -> String in
                let value = arguments[key]!
                let text: String
                if case let .string(string) = value { text = string } else { text = json(value) }
                return "<parameter=\(xmlSafe(key))>\n\(xmlSafe(text))\n</parameter>"
            }.joined(separator: "\n")
            prompt += assistantGenerationPrefix
            prompt += "<tool_call>\n<function=\(xmlSafe(name))>\n"
            if !parameters.isEmpty { prompt += parameters + "\n" }
            prompt += "</function>\n</tool_call><|im_end|>\n"
            // Unicode JSON escapes keep user-supplied delimiters inside JSON string values.
            let response = json(observation).replacingOccurrences(of: "<", with: "\\u003c").replacingOccurrences(of: ">", with: "\\u003e")
            prompt += "<|im_start|>user\n<tool_response>\n" + response + "\n</tool_response><|im_end|>\n"
        }
        return prompt + assistantGenerationPrefix
    }

    private static func chatSafe(_ value: String) -> String {
        value.replacingOccurrences(of: "<|im_start|>", with: "&lt;|im_start|&gt;")
            .replacingOccurrences(of: "<|im_end|>", with: "&lt;|im_end|&gt;")
            .replacingOccurrences(of: "<|endoftext|>", with: "&lt;|endoftext|&gt;")
            .replacingOccurrences(of: "<tool_response>", with: "&lt;tool_response&gt;")
            .replacingOccurrences(of: "</tool_response>", with: "&lt;/tool_response&gt;")
    }

    private static func xmlSafe(_ value: String) -> String {
        chatSafe(value).replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func schemaObject(_ schema: LuminaToolSchema, groundedArguments: [String: LuminaJSONValue] = [:]) -> LuminaJSONValue {
        let properties = Dictionary(uniqueKeysWithValues: schema.parameters.map { parameter in
            var value: [String: LuminaJSONValue] = [
                "type": .string(parameter.type == .bool ? "boolean" : parameter.type == .dateISO8601 ? "string" : parameter.type.rawValue),
                "description": .string(String(parameter.description.prefix(160)))
            ]
            if parameter.type == .dateISO8601 { value["format"] = .string("date-time") }
            if let grounded = groundedArguments[parameter.name] { value["const"] = grounded }
            return (parameter.name, LuminaJSONValue.object(value))
        })
        return .object([
            "name": .string(schema.name),
            "description": .string(String(schema.description.prefix(180))),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(schema.parameters.filter { $0.required || groundedArguments[$0.name] != nil }.map { .string($0.name) })
            ])
        ])
    }

    public static func json(_ value: LuminaJSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Bound individual payload fields; never cut serialized JSON or the latest failure envelope.
    public static func compactOutput(_ output: [String: LuminaJSONValue], preserveFailure: Bool) -> [String: LuminaJSONValue] {
        output.reduce(into: [:]) { result, item in
            result[item.key] = preserveFailure && item.key == "failure"
                ? item.value : compact(item.value, key: item.key)
        }
    }

    private static func compact(_ value: LuminaJSONValue, key: String) -> LuminaJSONValue {
        switch value {
        case let .string(text):
            let protected = ["id", "identifier", "date", "time", "zone", "code"].contains(where: key.lowercased().contains)
            let limit = protected ? 2048 : 400
            return .string(text.count > limit ? String(text.prefix(limit)) + "…" : text)
        case let .array(values):
            // Search results carry IDs needed by later writes. Keep every record, reducing
            // long bodies per field instead of silently dropping possible matches.
            return .array(values.map { compact($0, key: key) })
        case let .object(object):
            return .object(object.reduce(into: [:]) { result, item in
                result[item.key] = compact(item.value, key: item.key)
            })
        default: return value
        }
    }

    private static func domain(_ name: String) -> String { String(name.split(separator: ".").first ?? "") }

    private static func score(_ schema: LuminaToolSchema, query: String) -> Int {
        var score = query.contains(schema.name.lowercased()) ? 200 : 0
        for word in capabilityKeywords[schema.name, default: []] where query.contains(word) { score += 30 }
        let description = schema.description.lowercased()
        for word in query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) where word.count >= 3 {
            if description.contains(word) { score += 2 }
        }
        let reminder = ["提醒", "待办", "reminder"].contains(where: query.contains)
        let calendar = ["日程", "日历", "会议", "calendar", "meeting"].contains(where: query.contains)
        if (reminder && domain(schema.name) == "reminder") || (calendar && domain(schema.name) == "calendar") {
            score = max(score, 30)
        }
        let notification = ["通知", "notification", "notify"].contains(where: query.contains)
        if schema.name == "notification.schedule" && !notification { return 0 }
        if domain(schema.name) == "reminder" && notification && !query.contains("提醒事项") && !query.contains("待办") && !query.contains("reminder") { return 0 }
        let update = ["修改", "改成", "改到", "改为", "调整", "推迟", "改日程", "改提醒", "update", "reschedule", "change"].contains(where: query.contains)
        let delete = ["删除", "取消", "delete", "remove", "cancel"].contains(where: query.contains)
        let complete = ["完成", "complete", "done"].contains(where: query.contains)
        let scheduleDomain = domain(schema.name) == "calendar" || (reminder && domain(schema.name) == "reminder")
        let creating = ["提醒我", "创建", "新增", "安排", "create", "schedule", "remind me"].contains(where: query.contains)
        if scheduleDomain && schema.sideEffect != .readOnly {
            if schema.name.hasSuffix(".update") && !update { return 0 }
            if schema.name.hasSuffix(".delete") && !delete { return 0 }
            if schema.name.hasSuffix(".complete") && !complete { return 0 }
            if schema.name.hasSuffix(".create") && (update || delete || complete) && !creating { return 0 }
        }
        if scheduleDomain && score > 0 {
            if update { score += schema.name.hasSuffix(".update") ? 90 : (schema.name.hasSuffix(".search") ? 50 : -25) }
            else if delete { score += schema.name.hasSuffix(".delete") ? 90 : (schema.name.hasSuffix(".search") ? 50 : -25) }
            else if complete && domain(schema.name) == "reminder" { score += schema.name.hasSuffix(".complete") ? 90 : (schema.name.hasSuffix(".search") ? 50 : -25) }
            else if ["提醒我", "创建", "新增", "安排", "create", "schedule", "remind me"].contains(where: query.contains) {
                score += schema.name.hasSuffix(".create") ? 90 : 0
            }
        }
        return max(0, score)
    }

    private static let prerequisites: [String: String] = [
        "calendar.update": "calendar.search", "calendar.delete": "calendar.search",
        "reminder.update": "reminder.search", "reminder.complete": "reminder.search", "reminder.delete": "reminder.search",
        "contacts.update": "contacts.search", "contacts.open": "contacts.search",
        "ledger.update": "ledger.search", "ledger.delete": "ledger.search",
        "subscription.remove": "subscription.list", "file.read_note": "file.list_notes",
        "file.update_note": "file.list_notes", "file.delete_note": "file.list_notes"
    ]

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
        "notification.schedule": ["通知", "稍后通知", "notification", "notify"],
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

}
