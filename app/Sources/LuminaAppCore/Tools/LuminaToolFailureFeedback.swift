import Foundation
import LuminaAgentRuntime

/// The model receives one machine-readable correction next to the actual tool output.
/// This information never grants permission and never invents values or observations.
public enum LuminaToolFailureFeedback {
    public static func schemaValue(_ schema: LuminaToolSchema) -> LuminaJSONValue {
        var properties: [String: LuminaJSONValue] = [:]
        for parameter in schema.parameters {
            var property: [String: LuminaJSONValue] = [
                "type": .string(parameter.type == .bool ? "boolean" : parameter.type == .dateISO8601 ? "string" : parameter.type.rawValue),
                "description": .string(parameter.description)
            ]
            if parameter.type == .dateISO8601 { property["format"] = .string("date-time") }
            properties[parameter.name] = .object(property)
        }
        return .object([
            "name": .string(schema.name),
            "description": .string(schema.description),
            "parameters": .object([
                "type": .string("object"),
                "properties": .object(properties),
                "required": .array(schema.parameters.filter(\.required).map { .string($0.name) })
            ])
        ])
    }

    public static func payload(
        code: String,
        reason: String,
        toolName: String,
        arguments: [String: LuminaJSONValue],
        schema: LuminaToolSchema?,
        fieldErrors: [LuminaJSONValue] = [],
        suggestedCall: LuminaJSONValue = .null,
        missingInformation: [String] = [],
        retryPolicy: String,
        guidance: String
    ) -> LuminaJSONValue {
        .object([
            "code": .string(code), "reason": .string(reason),
            "toolName": .string(toolName), "arguments": .object(arguments),
            "fieldErrors": .array(fieldErrors), "toolSchema": schema.map(schemaValue) ?? .null,
            "suggestedCall": suggestedCall,
            "missingInformation": .array(missingInformation.map(LuminaJSONValue.string)),
            "retryPolicy": .string(retryPolicy), "guidance": .string(guidance)
        ])
    }

    public static func validationFailure(
        schema: LuminaToolSchema,
        arguments: [String: LuminaJSONValue],
        code: String = "invalid_parameters",
        reason: String,
        field: String,
        guidance: String,
        needsCurrentTime: Bool = false
    ) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(), toolName: schema.name, status: .failed,
            output: ["failure": payload(
                code: code, reason: reason, toolName: schema.name, arguments: arguments,
                schema: schema, fieldErrors: [.object(["field": .string(field), "reason": .string(reason)])],
                suggestedCall: needsCurrentTime ? currentTimeCall : .null,
                missingInformation: arguments[field] == nil ? [field] : [],
                retryPolicy: needsCurrentTime ? "prerequisite" : "correct_arguments", guidance: guidance
            )], content: [.text(reason)], errorMessage: reason, validationFailed: true
        )
    }

    public static func enrich(
        _ result: LuminaToolResult,
        arguments: [String: LuminaJSONValue],
        schema: LuminaToolSchema
    ) -> LuminaToolResult {
        var result = result
        let observation = enrichedObservation(
            LuminaReActObservation(toolName: result.toolName, status: result.status,
                                   summary: result.errorMessage ?? "Tool execution failed.",
                                   output: result.output, errorMessage: result.errorMessage),
            arguments: arguments, availableTools: [schema]
        )
        result.output = observation.output
        return result
    }

    public static func enrichedObservation(
        _ observation: LuminaReActObservation,
        arguments: [String: LuminaJSONValue] = [:],
        availableTools: [LuminaToolSchema],
        request: String = "",
        trace: LuminaReActTrace = .init()
    ) -> LuminaReActObservation {
        guard observation.status != .succeeded else { return observation }
        var observation = observation
        // A tool or runtime validator knows more than a string-based adapter does.
        if case .object = observation.output["failure"] {
            let scheduled = addingScheduleCorrection(to: observation, arguments: arguments, tools: availableTools, request: request, trace: trace)
            return addingIdentifierLookup(to: scheduled, arguments: arguments, tools: availableTools, request: request, trace: trace)
        }
        let schema = availableTools.first { $0.name == observation.toolName }
        let reason = observation.errorMessage ?? observation.summary
        let text = (reason + " " + observation.summary).lowercased()
        var code = "execution_failed"
        var retryPolicy = "stop"
        var guidance = "Explain the failure to the user. Do not claim success."
        var fields: [LuminaJSONValue] = []
        var missing: [String] = []
        let suggestedCall: LuminaJSONValue = .null
        var candidates: [LuminaToolSchema] = []
        if text.contains("not registered") || text.contains("unknown tool") || text.contains("unregistered tool") || text.contains("tool is deferred") || text.contains("tool is not callable") {
            code = "unknown_tool"; retryPolicy = "discover_tool"
            candidates = relatedTools(name: observation.toolName, tools: availableTools)
            guidance = "Choose an exact registered tool name from availableTools and follow its schema. Preserve the user's intended operation. Never invent a tool name."
        } else if observation.status == .cancelled || text.contains("cancelled") || text.contains("canceled") || text.contains("用户取消") {
            code = "cancelled"
            guidance = "The operation was cancelled. Stop this operation and tell the user; do not retry or switch tools to bypass cancellation."
        } else if observation.status == .denied || text.contains("permission") || text.contains("权限") || text.contains("授权") || text.contains("not authorized") {
            code = "permission_denied"; retryPolicy = "request_permission"
            guidance = "Stop this operation and explain the required user authorization. Do not retry or change tools to bypass the permission decision."
        } else if let schema {
            let validationFields = parameterErrors(arguments: arguments, schema: schema)
            let parameterText = text.contains("missing required") || text.contains("invalid type") || text.contains("allowed enum") || text.contains("json object") || text.contains("failed validation") || text.contains("缺少") || text.contains("无效") || text.contains("invalid") || text.contains("iso8601") || text.contains("在过去") || text.contains("in the past") || text.contains("必须晚于")
            if parameterText {
                code = text.contains("identifier") || text.contains("object id") ? "missing_identifier" : "invalid_parameters"
                fields = validationFields
                for parameter in schema.parameters where parameter.required && arguments[parameter.name] == nil {
                    missing.append(parameter.name)
                }
                // Legacy text does not prove whether a write happened. Give corrections but do not authorize replay.
                retryPolicy = schema.sideEffect == .readOnly ? "correct_arguments" : "verify_before_retry"
                guidance = "Use the exact toolSchema names and JSON types. Fill values only from the user request and actual observations. This legacy error does not establish whether a write occurred; do not automatically repeat a write."
                if code == "missing_identifier" {
                    guidance += " Search the corresponding objects first and use the real returned identifier; ask the user if the result is ambiguous."
                    missing.append("identifier from a successful search observation")
                }
            } else if schema.sideEffect != .readOnly {
                code = "execution_uncertain"; retryPolicy = "verify_before_retry"
                guidance = "The write outcome is uncertain. Stop automatic retries and report the failure. Verify actual state with a read-only tool before any user-authorized retry; do not create duplicates."
            }
        }
        var failure = payload(code: code, reason: reason, toolName: observation.toolName,
                              arguments: arguments, schema: schema, fieldErrors: fields,
                              suggestedCall: suggestedCall, missingInformation: missing,
                              retryPolicy: retryPolicy, guidance: guidance)
        if case var .object(object) = failure, !candidates.isEmpty {
            object["availableTools"] = .array(candidates.map(schemaValue))
            failure = .object(object)
        }
        observation.output["failure"] = failure
        return observation
    }

    /// Computed host facts based only on this request's successful device clock observation.
    /// These hints are not tool observations and do not execute or route an operation.
    public static func scheduleHints(request: String, trace: LuminaReActTrace) -> [LuminaJSONValue] {
        guard let snapshot = observedClock(trace) else { return [] }
        return LuminaTemporalParser.strictScheduleTargets(request, now: snapshot.date, calendar: snapshot.calendar).map { target in
            .object([
                "clause": .string(target.clause), "dateISO": .string(iso(target.date, calendar: snapshot.calendar)),
                "toolDomain": target.toolDomain.map(LuminaJSONValue.string) ?? .null,
                "basis": .object(["toolName": .string("device.current_time"), "iso8601": .string(snapshot.iso), "timeZoneIdentifier": .string(snapshot.calendar.timeZone.identifier)])
            ])
        }
    }

    /// Existing-object writes use identities from real lookup results, never a model's guessed title-as-ID.
    public static func missingObservedIdentifier(request: String, trace: LuminaReActTrace, call: LuminaToolCall, availableTools: [LuminaToolSchema]) -> [String: LuminaJSONValue]? {
        guard let schema = availableTools.first(where: { $0.name == call.toolName }), schema.sideEffect != .readOnly,
              let operation = call.toolName.split(separator: ".").last,
              ["update", "delete", "remove", "complete", "cancel"].contains(String(operation)),
              let idParameter = schema.parameters.first(where: { ["id", "identifier"].contains($0.name) }) else { return nil }
        // Explicit bulk operations have their own existing permission/confirmation path.
        if !idParameter.required, call.arguments[idParameter.name] == nil,
           schema.parameters.contains(where: { $0.name == "all" }), call.arguments.bool("all") == true { return nil }
        let id = call.arguments.string(idParameter.name) ?? ""
        if explicitIdentifier(id, in: request) { return nil }
        let domain = String(call.toolName.split(separator: ".").first ?? "")
        let lookupNames = [domain + ".search", domain + ".list", domain + ".lookup"]
        let lookups = lookupNames.compactMap { name in
            availableTools.first { $0.name == name && $0.sideEffect == .readOnly }
        }
        for observation in trace.observations where observation.status == .succeeded && lookups.contains(where: { $0.name == observation.toolName }) {
            if identifiers(in: observation).contains(where: { sameIdentifier($0, id) }) { return nil }
        }
        let lookup = lookups.first
        let query = originalLookupQuery(in: request, domain: domain)
        var suggestion: LuminaJSONValue = .null
        var missing = ["\(idParameter.name) from a successful \(lookup?.name ?? (domain + ".search/list")) observation in this request"]
        if let lookup {
            var lookupArguments: [String: LuminaJSONValue] = [:]
            let needsQuery = lookup.parameters.contains { $0.name == "query" }
            if needsQuery, let query { lookupArguments["query"] = .string(query) }
            if (!needsQuery || query != nil), parameterErrors(arguments: lookupArguments, schema: lookup).isEmpty {
                suggestion = .object(["toolName": .string(lookup.name), "arguments": .object(lookupArguments)])
            } else if needsQuery, query == nil {
                missing.append("the original object's name or an unambiguous lookup result; the new title is not a search target")
            }
        }
        let reason = "\(idParameter.name) has not been observed in a successful lookup for this object type in the current request. No write was performed; a title cannot be used as an identifier."
        let value = payload(
            code: "missing_observed_identifier", reason: reason, toolName: call.toolName, arguments: call.arguments, schema: schema,
            fieldErrors: [.object(["field": .string(idParameter.name), "reason": .string(reason), "expectedSource": .string(lookup?.name ?? (domain + ".search/list"))])],
            suggestedCall: suggestion, missingInformation: missing, retryPolicy: "prerequisite",
            guidance: "First use the registered lookup schema to find the original object, then pass its actual returned id/identifier. Use only the user's original target name for query, never the replacement title from an update. If no original target can be identified, ask the user instead of inventing an ID or a query."
        )
        guard case var .object(failure) = value else { return nil }
        failure["availableTools"] = .array(lookups.map(schemaValue))
        return failure
    }

    private static func identifiers(in observation: LuminaReActObservation) -> Set<String> {
        // Prefer the structured record list even when empty; do not resurrect IDs from stale summaries.
        if let items = observation.output["items"] { return recordIdentifiers(items) }
        let collections = ["events", "reminders", "contacts", "records", "transactions", "subscriptions", "results", "matches"]
        var foundCollection = false
        var ids = Set<String>()
        for key in collections {
            if let value = observation.output[key] {
                foundCollection = true
                ids.formUnion(recordIdentifiers(value))
            }
        }
        return foundCollection ? ids : bracketIdentifiers(observation.summary)
    }

    private static func addingIdentifierLookup(to observation: LuminaReActObservation, arguments: [String: LuminaJSONValue], tools: [LuminaToolSchema], request: String, trace: LuminaReActTrace) -> LuminaReActObservation {
        guard case var .object(failure) = observation.output["failure"],
              failure.string("code") == "validation_failed",
              case let .array(errors) = failure["fieldErrors"], errors.contains(where: { error in
                  guard case let .object(details) = error else { return false }
                  return ["id", "identifier"].contains(details.string("field") ?? "")
              }) else { return observation }
        var knownArguments = arguments
        if knownArguments.isEmpty, case let .object(original) = failure["arguments"] { knownArguments = original }
        let call = LuminaToolCall(toolName: observation.toolName, arguments: knownArguments)
        guard let lookup = missingObservedIdentifier(request: request, trace: trace, call: call, availableTools: tools) else { return observation }
        // Runtime may reject a missing required ID before beforeTool runs; keep its original diagnosis.
        for key in ["suggestedCall", "missingInformation", "availableTools", "guidance", "retryPolicy"] {
            failure[key] = lookup[key]
        }
        var updated = observation
        updated.output["failure"] = .object(failure)
        return updated
    }

    private static func recordIdentifiers(_ value: LuminaJSONValue) -> Set<String> {
        switch value {
        case let .array(records):
            return records.reduce(into: Set<String>()) { $0.formUnion(recordIdentifiers($1)) }
        case let .object(record):
            return Set([record.string("id"), record.string("identifier")].compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            })
        case let .string(summary): return bracketIdentifiers(summary)
        default: return []
        }
    }

    private static func bracketIdentifiers(_ summary: String) -> Set<String> {
        Set(regexCaptures("(?m)^\\s*(?:[-*]\\s*)?\\[id=([^\\]\\r\\n]+)\\]", in: summary).compactMap { $0.count > 1 ? $0[1] : nil })
    }

    private static func sameIdentifier(_ lhs: String, _ rhs: String) -> Bool {
        guard !rhs.isEmpty else { return false }
        if let first = UUID(uuidString: lhs), let second = UUID(uuidString: rhs) { return first == second }
        return lhs == rhs
    }

    private static func explicitIdentifier(_ id: String, in request: String) -> Bool {
        guard !id.isEmpty else { return false }
        let escaped = NSRegularExpression.escapedPattern(for: id)
        if UUID(uuidString: id) != nil {
            return !regexCaptures("(?<![A-Za-z0-9-])" + escaped + "(?![A-Za-z0-9-])", in: request).isEmpty
        }
        guard !regexCaptures("^[A-Za-z0-9][A-Za-z0-9._:@/+\\-]{7,}$", in: id).isEmpty else { return false }
        return !regexCaptures("(?:(?<![A-Za-z])id(?![A-Za-z])|(?<![A-Za-z])identifier(?![A-Za-z])|标识符|编号)\\s*[:=：]\\s*[\"'“「]?" + escaped + "(?![A-Za-z0-9._:@/+\\-])", in: request).isEmpty
    }

    private static func originalLookupQuery(in request: String, domain: String) -> String? {
        // Cut off the new value before examining either quoted or unquoted original names.
        let markers = ["改名为", "重命名为", "改为", "改成", "改到", "修改为", "更新为", "调整到", "推迟到", "提前到", " to "]
        let ranges = markers.compactMap { request.range(of: $0, options: .caseInsensitive) }
        let source = ranges.min(by: { $0.lowerBound < $1.lowerBound }).map { String(request[..<$0.lowerBound]) } ?? request
        let quoted = regexCaptures("[\"“「『《']([^\"”」』》'\\r\\n]+)[\"”」』》']", in: source).compactMap { groups -> String? in
            guard groups.count > 1 else { return nil }
            let value = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
        let uniqueQuoted = Set(quoted)
        if uniqueQuoted.count == 1 { return uniqueQuoted.first }
        if !uniqueQuoted.isEmpty { return nil }
        let nouns: [String]
        switch domain {
        case "calendar": nouns = ["日历事件", "日程", "会议", "calendar event", "event", "meeting"]
        case "reminder": nouns = ["提醒事项", "提醒", "待办", "reminder"]
        case "contacts": nouns = ["联系人", "contact"]
        case "ledger": nouns = ["账目", "账单", "记录", "transaction", "record"]
        case "subscription": nouns = ["订阅源", "订阅", "subscription"]
        default: return nil
        }
        let nounPattern = nouns.map(NSRegularExpression.escapedPattern).joined(separator: "|")
        let patterns = [
            "(?:\(nounPattern))\\s*(?:名为|叫做|标题为)?\\s*([^，,；;。\\r\\n]{1,80})$",
            "(?:删除|取消|完成|修改|更新|把|将)\\s*([^，,；;。\\r\\n]{1,80}?)(?:的)?(?:\(nounPattern))$"
        ]
        for pattern in patterns {
            if let groups = regexCaptures(pattern, in: source).first, groups.count > 1 {
                let value = groups[1].trimmingCharacters(in: .whitespacesAndNewlines)
                // A time, a pronoun, or a changed field is not an original object name.
                let ambiguous = ["今天", "明天", "后天", "早上", "上午", "下午", "晚上", "点", "标题", "备注", "时间", "金额", "这个", "那个", "它", "的", "today", "tomorrow", "this", "that"]
                if !value.isEmpty, !ambiguous.contains(where: value.lowercased().contains) { return value }
            }
        }
        return nil
    }

    private static func regexCaptures(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let source = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (0..<match.numberOfRanges).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }

    public static func scheduledTargetMismatch(request: String, trace: LuminaReActTrace, call: LuminaToolCall, schema: LuminaToolSchema) -> [String: LuminaJSONValue]? {
        guard let snapshot = observedClock(trace),
              let target = uniqueTarget(request: request, trace: trace, toolName: call.toolName, arguments: call.arguments),
              let field = scheduledDateField(toolName: call.toolName) else { return nil }
        let suppliedDate: Date?
        if call.toolName == "notification.schedule", let interval = call.arguments.number("timeIntervalSeconds"), call.arguments["dateISO"] == nil {
            suppliedDate = snapshot.date.addingTimeInterval(interval)
        } else {
            suppliedDate = call.arguments.string(field).flatMap(parseDate)
        }
        if let suppliedDate, abs(suppliedDate.timeIntervalSince(target.date)) < 1 { return nil }
        let targetISO = iso(target.date, calendar: snapshot.calendar)
        let reason = "\(field) does not match the user's explicit time. From the observed device time, ‘\(target.clause)’ means \(targetISO). No write was performed."
        let suggestion = target.date > snapshot.date ? correctedScheduledCall(schema: schema, arguments: call.arguments, field: field, target: target.date, calendar: snapshot.calendar) : .null
        let value = payload(
            code: "requested_time_mismatch", reason: reason, toolName: call.toolName, arguments: call.arguments, schema: schema,
            fieldErrors: [.object(["field": .string(field), "reason": .string("Use the host-computed date for the explicit requested time."), "expectedDateISO": .string(targetISO)])],
            suggestedCall: suggestion,
            missingInformation: target.date <= snapshot.date ? ["a future time confirmed by the user"] : [],
            retryPolicy: target.date <= snapshot.date ? "stop" : "correct_arguments",
            guidance: target.date <= snapshot.date
                ? "The user's explicit target is already in the past. Explain this and ask for a future time; do not silently move it to another day."
                : "The device clock was already read successfully. Use suggestedCall when present; it contains the original known arguments with only the explicit target time corrected. Do not read the clock again, invent missing values, or change the user's operation."
        )
        guard case let .object(failure) = value else { return nil }
        return failure
    }

    private static func addingScheduleCorrection(to observation: LuminaReActObservation, arguments: [String: LuminaJSONValue], tools: [LuminaToolSchema], request: String, trace: LuminaReActTrace) -> LuminaReActObservation {
        guard case var .object(failure) = observation.output["failure"],
              let code = failure.string("code"),
              ["invalid_date", "past_date", "invalid_date_range", "requested_time_mismatch", "missing_current_time", "validation_failed", "invalid_parameters"].contains(code),
              let schema = tools.first(where: { $0.name == observation.toolName }),
              let field = scheduledDateField(toolName: schema.name), let snapshot = observedClock(trace) else { return observation }
        var knownArguments = arguments
        if knownArguments.isEmpty, case let .object(original) = failure["arguments"] { knownArguments = original }
        if code == "invalid_parameters" {
            // A conflicting notification mode is deterministic only after user intent resolves the target.
            guard schema.name == "notification.schedule", knownArguments["dateISO"] != nil,
                  knownArguments["timeIntervalSeconds"] != nil else { return observation }
        }
        if code == "validation_failed" {
            guard case let .array(errors) = failure["fieldErrors"], errors.contains(where: { error in
                guard case let .object(detail) = error else { return false }
                return detail.string("field") == field
            }) else { return observation }
        }
        guard let target = uniqueTarget(request: request, trace: trace, toolName: schema.name, arguments: knownArguments) else { return observation }
        let targetISO = iso(target.date, calendar: snapshot.calendar)
        failure["suggestedCall"] = target.date > snapshot.date ? correctedScheduledCall(schema: schema, arguments: knownArguments, field: field, target: target.date, calendar: snapshot.calendar) : .null
        let durationCorrection = target.date > snapshot.date
            ? observedDurationCorrection(request: request, trace: trace, arguments: knownArguments, schema: schema, tools: tools)
            : nil
        if let durationCorrection { failure["suggestedCall"] = durationCorrection }
        failure["retryPolicy"] = .string(target.date > snapshot.date ? "correct_arguments" : "stop")
        failure["hostGuidance"] = .object(["clause": .string(target.clause), "dateISO": .string(targetISO), "observedISO8601": .string(snapshot.iso), "timeZoneIdentifier": .string(snapshot.calendar.timeZone.identifier)])
        failure["guidance"] = .string(target.date > snapshot.date
            ? "The device time is already known. The host computed \(targetISO) from the explicit user clause using that observation's time zone. Use suggestedCall if supplied; otherwise fill the remaining required fields from user intent and real observations. Do not read device.current_time again. No action has been executed by this hint." + (durationCorrection == nil ? "" : " The suggested start and end preserve the duration from the successful calendar.search record, as the user requested; no duration was inferred from the failed arguments.")
            : "The explicit requested time is already in the past. Ask the user for a future time; do not change the date or repeatedly read the clock.")
        var updated = observation
        updated.output["failure"] = .object(failure)
        return updated
    }

    private static func observedDurationCorrection(request: String, trace: LuminaReActTrace, arguments: [String: LuminaJSONValue], schema: LuminaToolSchema, tools: [LuminaToolSchema]) -> LuminaJSONValue? {
        let text = request.lowercased()
        let preserveDuration = (text.contains("保持") && text.contains("时长")) || text.contains("时长不变") || text.contains("same duration") || (text.contains("keep") && text.contains("duration"))
        guard schema.name == "calendar.update", preserveDuration,
              let requestedID = arguments.string("id"),
              let suggestion = LuminaToolPromptPolicy.suggestedLookupMutation(
                  request: request, schemas: tools, trace: trace,
                  timeHints: scheduleHints(request: request, trace: trace)
              ),
              case let .object(call) = suggestion, case let .object(corrected) = call["arguments"],
              let observedID = corrected.string("id"), sameIdentifier(requestedID, observedID),
              let start = corrected.string("startDateISO").flatMap(parseDate),
              let end = corrected.string("endDateISO").flatMap(parseDate), end > start else { return nil }
        // Preserve any other requested changes; only the identity and the observed-duration dates come from the lookup suggestion.
        var merged = arguments
        for (key, value) in corrected { merged[key] = value }
        guard parameterErrors(arguments: merged, schema: schema).isEmpty else { return nil }
        return .object(["toolName": .string(schema.name), "arguments": .object(merged)])
    }

    private static func observedClock(_ trace: LuminaReActTrace) -> (date: Date, calendar: Calendar, iso: String)? {
        guard let observation = trace.observations.last(where: { $0.toolName == "device.current_time" && $0.status == .succeeded }),
              let iso = observation.output.string("iso8601"), let date = parseDate(iso),
              let zoneID = observation.output.string("timeZoneIdentifier"), let zone = TimeZone(identifier: zoneID) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return (date, calendar, iso)
    }

    private static func uniqueTarget(request: String, trace: LuminaReActTrace, toolName: String, arguments: [String: LuminaJSONValue]) -> LuminaStrictScheduleTarget? {
        guard let snapshot = observedClock(trace), scheduledDateField(toolName: toolName) != nil else { return nil }
        let targets = LuminaTemporalParser.strictScheduleTargets(request, now: snapshot.date, calendar: snapshot.calendar)
        let domain = String(toolName.split(separator: ".").first ?? "")
        let candidates = targets.filter { $0.toolDomain == domain || (targets.count == 1 && $0.toolDomain == nil) }
        if candidates.count == 1 { return candidates[0] }
        if let title = arguments.string("title")?.lowercased(), !title.isEmpty {
            let matching = candidates.filter { $0.clause.lowercased().contains(title) }
            if matching.count == 1 { return matching[0] }
        }
        return nil
    }

    private static func correctedScheduledCall(schema: LuminaToolSchema, arguments: [String: LuminaJSONValue], field: String, target: Date, calendar: Calendar) -> LuminaJSONValue {
        var corrected = arguments
        corrected[field] = .string(iso(target, calendar: calendar))
        if schema.name == "notification.schedule" { corrected.removeValue(forKey: "timeIntervalSeconds") }
        guard parameterErrors(arguments: corrected, schema: schema).isEmpty else { return .null }
        if let rawEnd = corrected.string("endDateISO") {
            guard let end = parseDate(rawEnd), end > target else { return .null }
        }
        return .object(["toolName": .string(schema.name), "arguments": .object(corrected)])
    }

    private static func scheduledDateField(toolName: String) -> String? {
        switch toolName {
        case "reminder.create", "reminder.update": return "dueDateISO"
        case "calendar.create", "calendar.update": return "startDateISO"
        case "notification.schedule": return "dateISO"
        default: return nil
        }
    }

    private static func iso(_ date: Date, calendar: Calendar) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = calendar.timeZone
        return formatter.string(from: date)
    }

    /// Validation is performed before requesting permission or touching a store.
    public static func validateScheduledWrite(
        schema: LuminaToolSchema,
        arguments: [String: LuminaJSONValue],
        now: Date = Date()
    ) -> LuminaToolResult? {
        if let issue = parameterErrors(arguments: arguments, schema: schema).first,
           case let .object(details) = issue {
            return validationFailure(schema: schema, arguments: arguments,
                                     reason: details.string("reason") ?? "Invalid parameter.",
                                     field: details.string("field") ?? "arguments",
                                     guidance: "Follow toolSchema exactly. Supply missing values from the user request or real observations; ask the user if a required value is unavailable.")
        }
        for field in ["startDateISO", "endDateISO", "dueDateISO", "dateISO"] {
            guard let value = arguments[field] else { continue }
            guard case let .string(raw) = value, let date = parseDate(raw) else {
                return validationFailure(schema: schema, arguments: arguments, code: "invalid_date",
                                         reason: "\(field) must be a valid ISO8601 date-time with a time zone; no write was performed.", field: field,
                                         guidance: "Read device.current_time, then construct a valid ISO8601 date-time from the user's requested time and the observed time zone. Never replace an invalid date with an undated item.", needsCurrentTime: true)
            }
            guard date > now else {
                return validationFailure(schema: schema, arguments: arguments, code: "past_date",
                                         reason: "\(field) is in the past; no write was performed.", field: field,
                                         guidance: "Call device.current_time({}), then recompute the requested future ISO8601 date using its current date and time zone. Preserve the user's title and intended time.", needsCurrentTime: true)
            }
        }
        if let start = arguments.string("startDateISO").flatMap(parseDate),
           let end = arguments.string("endDateISO").flatMap(parseDate), end <= start {
            return validationFailure(schema: schema, arguments: arguments, code: "invalid_date_range",
                                     reason: "endDateISO must be later than startDateISO; no write was performed.", field: "endDateISO",
                                     guidance: "Keep the user-requested start time and provide an end time later than startDateISO, using only the requested duration or end time.")
        }
        if schema.name == "notification.schedule" {
            if arguments["dateISO"] != nil && arguments["timeIntervalSeconds"] != nil {
                return validationFailure(schema: schema, arguments: arguments,
                                         reason: "Provide exactly one of dateISO or timeIntervalSeconds; no notification was scheduled.", field: "dateISO",
                                         guidance: "Use dateISO for an absolute time or timeIntervalSeconds for a requested relative delay, without both fields.")
            }
            if let interval = arguments.number("timeIntervalSeconds"), !interval.isFinite || interval <= 0 {
                return validationFailure(schema: schema, arguments: arguments,
                                         reason: "timeIntervalSeconds must be a finite positive number; no notification was scheduled.", field: "timeIntervalSeconds",
                                         guidance: "Convert the delay requested by the user into a positive number of seconds.")
            }
            if arguments["dateISO"] == nil && arguments["timeIntervalSeconds"] == nil {
                return validationFailure(schema: schema, arguments: arguments,
                                         reason: "A notification requires dateISO or timeIntervalSeconds; no notification was scheduled.", field: "dateISO",
                                         guidance: "Obtain the user's intended time. For a relative date, read device.current_time first; do not invent a default delay.")
            }
        }
        return nil
    }

    public static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    public static func requiresCurrentTime(requestText: String, toolName: String, arguments: [String: LuminaJSONValue]) -> Bool {
        let isTimedWrite = ["reminder.create", "reminder.update", "calendar.create", "calendar.update", "notification.schedule"].contains(toolName)
        guard isTimedWrite else { return false }
        let text = requestText.lowercased()
        let relativeTerms = ["今天", "明天", "后天", "大后天", "今晚", "明早", "明晚", "早上", "上午", "中午", "下午", "傍晚", "晚上", "周", "星期", "下月", "下个月", "明年", "小时后", "分钟后", "秒后", "天后", "today", "tomorrow", "tonight", "next ", "this ", "in "]
        return arguments["timeIntervalSeconds"] != nil || relativeTerms.contains { text.contains($0) }
    }

    public static let currentTimeCall: LuminaJSONValue = .object(["toolName": .string("device.current_time"), "arguments": .object([:])])

    private static func parameterErrors(arguments: [String: LuminaJSONValue], schema: LuminaToolSchema) -> [LuminaJSONValue] {
        var errors: [LuminaJSONValue] = []
        for parameter in schema.parameters {
            guard let value = arguments[parameter.name] else {
                if parameter.required {
                    errors.append(.object(["field": .string(parameter.name), "reason": .string("Missing required parameter \(parameter.name)."), "expectedType": .string(parameter.type.rawValue)]))
                }
                continue
            }
            let valid: Bool
            switch (parameter.type, value) {
            case (.string, .string), (.dateISO8601, .string), (.number, .number), (.bool, .bool), (.object, .object), (.array, .array): valid = true
            default: valid = false
            }
            if !valid {
                errors.append(.object(["field": .string(parameter.name), "reason": .string("Invalid type for \(parameter.name); expected \(parameter.type.rawValue)."), "expectedType": .string(parameter.type.rawValue)]))
            } else if parameter.required, case let .string(text) = value, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append(.object(["field": .string(parameter.name), "reason": .string("\(parameter.name) must not be empty.")]))
            }
        }
        return errors
    }

    private static func relatedTools(name: String, tools: [LuminaToolSchema]) -> [LuminaToolSchema] {
        let components = name.lowercased().split(separator: ".").map(String.init)
        var ranked: [(schema: LuminaToolSchema, score: Int)] = []
        for tool in tools {
            var score = 0
            for component in components where tool.name.lowercased().contains(component) { score += 1 }
            if score > 0 { ranked.append((schema: tool, score: score)) }
        }
        ranked.sort { lhs, rhs in
            lhs.score == rhs.score ? lhs.schema.name < rhs.schema.name : lhs.score > rhs.score
        }
        return ranked.prefix(3).map { $0.schema }
    }
}

/// Shared by production and isolated evaluation; all correction text stays in observation.output.failure.
public struct LuminaToolRecoveryRuntimePolicy: LuminaMatchingAgentRuntimeHook {
    public let matcher = LuminaAgentRuntimeHookMatcher(events: [.beforeTool, .stepContextReady])
    public init() {}

    public func handle(event: LuminaAgentRuntimeHookEvent, context: LuminaAgentRuntimeHookContext) async throws -> [LuminaAgentRuntimeHookDirective] {
        let observations = context.trace.steps.compactMap(\.observation)
        if event == .beforeTool, let call = context.toolCall {
            if let prior = failuresSinceLastSuccess(toolName: call.toolName, observations: observations).last,
               let failure = failureObject(prior, tools: context.availableTools),
               ["request_permission", "stop", "verify_before_retry"].contains(failure.string("retryPolicy") ?? "") {
                return [.fail(markdown: "操作已停止：\(failure.string("reason") ?? prior.summary)", reason: "Unsafe automatic retry was blocked.")]
            }
            if LuminaToolFailureFeedback.requiresCurrentTime(requestText: context.request.text, toolName: call.toolName, arguments: call.arguments),
               !observations.contains(where: validCurrentTime) {
                let reason = "本轮尚未读取设备当前时间，因此未执行写入。请先调用 device.current_time({})，再根据返回的 ISO 时间和时区计算用户要求的时间。"
                let schema = context.availableTools.first { $0.name == call.toolName }
                let payload = LuminaToolFailureFeedback.payload(
                    code: "missing_current_time", reason: reason, toolName: call.toolName,
                    arguments: call.arguments, schema: schema,
                    suggestedCall: LuminaToolFailureFeedback.currentTimeCall,
                    missingInformation: ["successful device.current_time observation for this request"],
                    retryPolicy: "prerequisite",
                    guidance: "No write was performed. Call device.current_time with an empty arguments object, then recompute the intended date using its ISO timestamp and timeZoneIdentifier. Preserve the user's objective and all known non-date parameters."
                )
                if case let .object(failure) = payload {
                    return [.rejectToolCallForValidation(reason: reason, failure: failure)]
                }
            }
            if let failure = LuminaToolFailureFeedback.missingObservedIdentifier(request: context.request.text, trace: context.trace, call: call, availableTools: context.availableTools) {
                return [.rejectToolCallForValidation(reason: failure.string("reason") ?? "Look up the original object and use its returned identifier.", failure: failure)]
            }
            if let schema = context.availableTools.first(where: { $0.name == call.toolName }),
               let failure = LuminaToolFailureFeedback.scheduledTargetMismatch(request: context.request.text, trace: context.trace, call: call, schema: schema) {
                return [.rejectToolCallForValidation(reason: failure.string("reason") ?? "The supplied time differs from the explicit requested time.", failure: failure)]
            }
        }
        if event == .stepContextReady, let last = observations.last,
           last.status != .succeeded,
           let failure = failureObject(last, tools: context.availableTools),
           let category = correctionCategory(failure) {
            let count = failuresSinceLastSuccess(toolName: last.toolName, observations: observations).filter { observation in
                guard let priorFailure = failureObject(observation, tools: context.availableTools) else { return false }
                return correctionCategory(priorFailure) == category
            }.count
            if count >= 2 {
                return [.fail(
                    markdown: "未能完成 \(last.toolName)：\(failure.string("reason") ?? last.summary)\n\n已尝试纠正一次，仍未通过校验，因此停止该操作。",
                    reason: "The same tool validation error persisted after one correction."
                )]
            }
        }
        return []
    }

    private func validCurrentTime(_ observation: LuminaReActObservation) -> Bool {
        observation.toolName == "device.current_time" && observation.status == .succeeded &&
            observation.output.string("iso8601").flatMap(LuminaToolFailureFeedback.parseDate) != nil &&
            observation.output.string("timeZoneIdentifier").flatMap(TimeZone.init(identifier:)) != nil
    }

    private func failuresSinceLastSuccess(toolName: String, observations: [LuminaReActObservation]) -> [LuminaReActObservation] {
        let start = observations.lastIndex { $0.toolName == toolName && $0.status == .succeeded }.map { $0 + 1 } ?? 0
        return observations.dropFirst(start).filter { $0.toolName == toolName && $0.status != .succeeded }
    }

    private func failureObject(_ observation: LuminaReActObservation, tools: [LuminaToolSchema]) -> [String: LuminaJSONValue]? {
        let enriched = LuminaToolFailureFeedback.enrichedObservation(observation, availableTools: tools)
        guard case let .object(failure) = enriched.output["failure"] else { return nil }
        return failure
    }

    private func correctionCategory(_ failure: [String: LuminaJSONValue]) -> String? {
        guard ["correct_arguments", "prerequisite"].contains(failure.string("retryPolicy") ?? "") else { return nil }
        let code = failure.string("code") ?? "invalid_parameters"
        let category = ["invalid_date", "past_date", "invalid_date_range", "requested_time_mismatch"].contains(code) ? "date_validation" : code
        guard case let .array(errors) = failure["fieldErrors"] else { return category }
        let fields = Set(errors.compactMap { error -> String? in
            guard case let .object(details) = error else { return nil }
            return details.string("field")
        }).sorted()
        // A newly exposed field needs its own correction; reporting order cannot reset the budget.
        return category + fields.map { "|\($0.utf8.count):\($0)" }.joined()
    }
}
