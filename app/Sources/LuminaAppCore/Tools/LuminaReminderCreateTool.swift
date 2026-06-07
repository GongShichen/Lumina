import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaReminderCreateTool: LuminaAgentTool {
    public let store: LuminaVolatileCalendarStore

    public init(store: LuminaVolatileCalendarStore) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
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

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let dueDate = Self.date(from: arguments.string("dueDateISO"))
        if let dueDate, dueDate < Date().addingTimeInterval(-300) {
            return Self.failedResult("reminder.create dueDateISO is in the past; call device.current_time and recompute a future ISO8601 time.")
        }
        let reminder = LuminaReminderItem(
            title: arguments.string("title") ?? "Agent Reminder",
            notes: arguments.string("notes"),
            dueDate: dueDate
        )
        let id = await store.addReminder(reminder)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id)],
            content: [.text("提醒已创建：\(reminder.title)")],
            rollbackToken: id
        )
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.removeReminder(id: token)
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func failedResult(_ message: String) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "reminder.create",
            status: .failed,
            output: ["summary": .string(message)],
            content: [.text(message)],
            errorMessage: message
        )
    }
}
