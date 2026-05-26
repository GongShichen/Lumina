import LuminaAgentClient
@preconcurrency import EventKit
import Foundation
import LuminaAppCore



enum LuminaEventKitManagementToolFactory {
    static func makeTools() -> [AnyLuminaAgentTool] {
        let store = EKEventStore()
        return [
            updateCalendarTool(store: store),
            deleteCalendarTool(store: store),
            availabilityTool(store: store),
            searchReminderTool(store: store),
            updateReminderTool(store: store),
            completeReminderTool(store: store),
            deleteReminderTool(store: store)
        ].map { $0.eraseToAnyTool() }
    }

    private static func updateCalendarTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "calendar.update", description: "修改真实系统日历事件。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
            param("id", "事件 identifier。"),
            param("title", "新标题。", required: false),
            param("startDateISO", "新的开始时间。", type: .dateISO8601, required: false),
            param("endDateISO", "新的结束时间。", type: .dateISO8601, required: false),
            param("notes", "备注。", required: false, sensitive: true)
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestCalendarAccess(store)
            guard let id = arguments.string("id"),
                  let event = store.event(withIdentifier: id) ?? store.calendarItem(withIdentifier: id) as? EKEvent else {
                return failed("calendar.update", "没有找到要修改的日历事件。")
            }
            if let title = arguments.string("title"), !title.isEmpty { event.title = title }
            if let start = date(arguments.string("startDateISO")) { event.startDate = start }
            if let end = date(arguments.string("endDateISO")) { event.endDate = end }
            if let notes = arguments.string("notes") { event.notes = notes }
            try store.save(event, span: .thisEvent, commit: true)
            return succeeded("calendar.update", "日程已更新：\(event.title ?? "Untitled")", [
                "identifier": .string(event.eventIdentifier ?? event.calendarItemIdentifier),
                "title": .string(event.title ?? "Untitled")
            ])
        }
    }

    private static func deleteCalendarTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "calendar.delete", description: "删除真实系统日历事件。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
            param("id", "事件 identifier。")
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestCalendarAccess(store)
            guard let id = arguments.string("id"),
                  let event = store.event(withIdentifier: id) ?? store.calendarItem(withIdentifier: id) as? EKEvent else {
                return failed("calendar.delete", "没有找到要删除的日历事件。")
            }
            try store.remove(event, span: .thisEvent, commit: true)
            return succeeded("calendar.delete", "日历事件已删除：\(event.title ?? "Untitled")", ["identifier": .string(id)])
        }
    }

    private static func availabilityTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "calendar.availability", description: "查询真实日历忙闲状态。", sensitivity: .privateData, params: [
            param("startDateISO", "开始时间。", type: .dateISO8601),
            param("endDateISO", "结束时间。", type: .dateISO8601)
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestCalendarAccess(store)
            let start = date(arguments.string("startDateISO")) ?? Date()
            let end = date(arguments.string("endDateISO")) ?? start.addingTimeInterval(3_600)
            let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
            let events = store.events(matching: predicate)
            let values = events.map { LuminaJSONValue.object([
                "identifier": .string($0.eventIdentifier ?? $0.calendarItemIdentifier),
                "title": .string($0.title ?? "Untitled"),
                "startDateISO": .string(iso($0.startDate))
            ]) }
            let summary = events.isEmpty ? "这段时间没有日程冲突。" : "这段时间有 \(events.count) 个日程。"
            return succeeded("calendar.availability", summary, ["busy": .bool(!events.isEmpty), "events": .array(values)])
        }
    }

    private static func searchReminderTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "reminder.search", description: "查询真实系统提醒事项。", sensitivity: .privateData, params: [
            param("query", "提醒关键词。", required: false),
            param("limit", "最多返回数量。", type: .number, required: false)
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestReminderAccess(store)
            let query = arguments.string("query")?.lowercased() ?? ""
            let limit = max(1, min(20, Int(arguments.number("limit") ?? 10)))
            let reminders = try await fetchReminders(store: store)
                .filter { query.isEmpty || ($0.title ?? "").lowercased().contains(query) }
                .prefix(limit)
            let values = reminders.map(reminderJSON)
            return succeeded("reminder.search", reminders.isEmpty ? "没有找到提醒事项。" : "找到 \(reminders.count) 条提醒事项。", ["reminders": .array(Array(values))])
        }
    }

    private static func updateReminderTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "reminder.update", description: "修改真实系统提醒事项。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
            param("id", "提醒 identifier。"),
            param("title", "新标题。", required: false),
            param("notes", "备注。", required: false, sensitive: true),
            param("dueDateISO", "截止时间。", type: .dateISO8601, required: false)
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestReminderAccess(store)
            guard let reminder = try await reminder(arguments, store: store) else {
                return failed("reminder.update", "没有找到要修改的提醒。")
            }
            if let title = arguments.string("title"), !title.isEmpty { reminder.title = title }
            if let notes = arguments.string("notes") { reminder.notes = notes }
            if let due = date(arguments.string("dueDateISO")) {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            }
            try store.save(reminder, commit: true)
            return succeeded("reminder.update", "提醒已更新：\(reminder.title ?? "Untitled")", ["identifier": .string(reminder.calendarItemIdentifier)])
        }
    }

    private static func completeReminderTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "reminder.complete", description: "标记真实系统提醒事项完成。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
            param("id", "提醒 identifier。")
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestReminderAccess(store)
            guard let reminder = try await reminder(arguments, store: store) else {
                return failed("reminder.complete", "没有找到要完成的提醒。")
            }
            reminder.isCompleted = true
            reminder.completionDate = Date()
            try store.save(reminder, commit: true)
            return succeeded("reminder.complete", "提醒已完成：\(reminder.title ?? "Untitled")", ["identifier": .string(reminder.calendarItemIdentifier)])
        }
    }

    private static func deleteReminderTool(store: EKEventStore) -> LuminaConfiguredTool {
        configured(name: "reminder.delete", description: "删除真实系统提醒事项。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
            param("id", "提醒 identifier。")
        ]) { arguments, cancellation in
            try cancellation.checkCancellation()
            try await requestReminderAccess(store)
            guard let reminder = try await reminder(arguments, store: store) else {
                return failed("reminder.delete", "没有找到要删除的提醒。")
            }
            try store.remove(reminder, commit: true)
            return succeeded("reminder.delete", "提醒已删除：\(reminder.title ?? "Untitled")", ["identifier": .string(reminder.calendarItemIdentifier)])
        }
    }

    private static func requestCalendarAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            guard try await LuminaSystemPermissionRequest.withTimeout(operation: {
                try await LuminaPermissionTimingRecorder.shared.record({
                    try await store.requestFullAccessToEvents()
                })
            }) else {
                throw AppToolError.permissionDenied("你没有授予日历完整访问权限。请允许 Lumina 访问日历后再试。")
            }
        case .denied:
            throw AppToolError.permissionDenied("日历权限已被拒绝。请到系统设置中允许 Lumina 访问日历。")
        case .restricted:
            throw AppToolError.permissionDenied("当前设备限制了日历访问。")
        case .writeOnly:
            throw AppToolError.permissionDenied("当前只有日历写入权限，读取或修改事件需要完整访问权限。")
        @unknown default:
            throw AppToolError.permissionDenied("当前日历权限状态不可用。")
        }
    }

    private static func requestReminderAccess(_ store: EKEventStore) async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess, .writeOnly:
            return
        case .notDetermined:
            guard try await LuminaSystemPermissionRequest.withTimeout(operation: {
                try await LuminaPermissionTimingRecorder.shared.record({
                    try await store.requestFullAccessToReminders()
                })
            }) else {
                throw AppToolError.permissionDenied("你没有授予提醒事项访问权限。请允许 Lumina 访问提醒事项后再试。")
            }
        case .denied:
            throw AppToolError.permissionDenied("提醒事项权限已被拒绝。请到系统设置中允许 Lumina 访问提醒事项。")
        case .restricted:
            throw AppToolError.permissionDenied("当前设备限制了提醒事项访问。")
        @unknown default:
            throw AppToolError.permissionDenied("当前提醒事项权限状态不可用。")
        }
    }

    private static func fetchReminders(store: EKEventStore) async throws -> [EKReminder] {
        let boxed = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UncheckedEventKitValue<[EKReminder]>, Error>) in
            let predicate = store.predicateForReminders(in: nil)
            store.fetchReminders(matching: predicate) { reminders in
                continuation.resume(returning: UncheckedEventKitValue(reminders ?? []))
            }
        }
        return boxed.value
    }

    private static func reminder(_ arguments: [String: LuminaJSONValue], store: EKEventStore) async throws -> EKReminder? {
        guard let id = arguments.string("id") else { return nil }
        if let reminder = store.calendarItem(withIdentifier: id) as? EKReminder {
            return reminder
        }
        return try await fetchReminders(store: store).first { $0.calendarItemIdentifier == id }
    }

    private static func reminderJSON(_ reminder: EKReminder) -> LuminaJSONValue {
        .object([
            "identifier": .string(reminder.calendarItemIdentifier),
            "title": .string(reminder.title ?? "Untitled"),
            "isCompleted": .bool(reminder.isCompleted),
            "dueDateISO": reminder.dueDateComponents?.date.map { .string(iso($0)) } ?? .null
        ])
    }
}



private func configured(
    name: String,
    description: String,
    sideEffect: LuminaToolSideEffect = .readOnly,
    sensitivity: LuminaToolSensitivity,
    params: [LuminaToolParameterSchema],
    handler: @escaping LuminaConfiguredTool.Handler
) -> LuminaConfiguredTool {
    LuminaConfiguredTool(schema: LuminaToolSchema(
        name: name,
        description: description,
        parameters: params,
        sideEffect: sideEffect,
        sensitivity: sensitivity,
        acceptedInputModalities: [.text, .structuredData],
        outputModalities: [.text, .structuredData]
    ), handler: handler)
}

private func param(_ name: String, _ description: String, type: LuminaToolParameterType = .string, required: Bool = true, sensitive: Bool = false) -> LuminaToolParameterSchema {
    LuminaToolParameterSchema(name: name, type: type, description: description, required: required, sensitive: sensitive)
}

private func succeeded(_ toolName: String, _ message: String, _ output: [String: LuminaJSONValue]) -> LuminaToolResult {
    LuminaToolResult(callID: UUID(), toolName: toolName, status: .succeeded, output: output.merging(["summary": .string(message)]) { current, _ in current }, content: [.markdown(message)])
}

private func failed(_ toolName: String, _ message: String) -> LuminaToolResult {
    LuminaToolResult(callID: UUID(), toolName: toolName, status: .failed, output: ["summary": .string(message)], content: [.markdown(message)], errorMessage: message)
}

private func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}
