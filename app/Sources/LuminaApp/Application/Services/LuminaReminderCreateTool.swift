import LuminaAgentRuntime
import LuminaAppCore
@preconcurrency import EventKit
import Foundation
import PersonalMemory

final class LuminaReminderCreateTool: LuminaAgentTool, @unchecked Sendable {
    private let eventStore = EKEventStore()

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "reminder.create",
            description: "创建系统提醒事项。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "提醒标题。"),
                LuminaToolParameterSchema(name: "notes", type: .string, description: "备注。", required: false, sensitive: true),
                LuminaToolParameterSchema(name: "dueDateISO", type: .string, description: "ISO8601 提醒时间。", required: false)
            ],
            sideEffect: .systemWrite,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData],
            idempotencyPolicy: "caller_keyed"
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        let dueDate = arguments.string("dueDateISO").flatMap(LuminaToolFailureFeedback.parseDate)
        do {
            try await requestReminderAccess()
        } catch AppToolError.permissionDenied(let reason) {
            return LuminaToolFailureFeedback.enrich(
                LuminaToolResult(callID: UUID(), toolName: schema.name, status: .denied, errorMessage: reason),
                arguments: arguments, schema: schema
            )
        }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        // A permission sheet can stay open beyond the requested due time.
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = arguments.string("title") ?? "Agent Reminder"
        reminder.notes = arguments.string("notes")
        if let dueDate {
            reminder.dueDateComponents = Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: dueDate)
        }
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        try eventStore.save(reminder, commit: true)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(reminder.calendarItemIdentifier),
                "title": .string(reminder.title ?? "Agent Reminder"),
                "dueDateISO": dueDate.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "executedArguments": .object(arguments)
            ],
            content: [.text("提醒已创建：\(reminder.title ?? "Agent Reminder")")],
            rollbackToken: reminder.calendarItemIdentifier
        )
    }

    func rollback(result: LuminaToolResult) async -> Bool {
        guard let identifier = result.rollbackToken,
              let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return false
        }
        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    private func requestReminderAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await LuminaSystemPermissionRequest.awaitDecision {
                try await self.eventStore.requestFullAccessToReminders()
            }
            if granted {
                return
            }
            throw AppToolError.permissionDenied("你没有授予提醒事项访问权限。请允许 Lumina 访问提醒事项后再试。")
        case .denied:
            throw AppToolError.permissionDenied("提醒事项权限已被拒绝。请到系统设置中允许 Lumina 访问提醒事项。")
        case .restricted:
            throw AppToolError.permissionDenied("当前设备限制了提醒事项访问，Lumina 无法创建提醒。")
        case .writeOnly:
            return
        @unknown default:
            throw AppToolError.permissionDenied("当前提醒事项权限状态不可用。")
        }
    }

}
