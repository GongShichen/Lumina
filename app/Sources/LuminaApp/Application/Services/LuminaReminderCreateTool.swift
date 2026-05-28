import LuminaAgentRuntime
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
        try await requestReminderAccess()
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = arguments.string("title") ?? "Agent Reminder"
        reminder.notes = arguments.string("notes")
        if let dueDate = Self.date(from: arguments.string("dueDateISO")) {
            guard dueDate >= Date().addingTimeInterval(-300) else {
                return Self.failedResult("提醒时间在过去：\(Self.string(from: dueDate))。请先用 device.current_time 获取当前时间，再重新计算未来提醒时间。")
            }
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: dueDate)
        }
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        try eventStore.save(reminder, commit: true)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(reminder.calendarItemIdentifier)],
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
            let granted = try await LuminaSystemPermissionRequest.withTimeout {
                try await LuminaPermissionTimingRecorder.shared.record {
                    try await self.eventStore.requestFullAccessToReminders()
                }
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

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func failedResult(_ message: String) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "reminder.create",
            status: .failed,
            output: ["reason": .string(message)],
            content: [.markdown("### 提醒未创建\n\n\(message)")],
            errorMessage: message
        )
    }
}
