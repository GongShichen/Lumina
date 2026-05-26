import LuminaAgentClient
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
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let reminder = LuminaReminderItem(
            title: arguments.string("title") ?? "Agent Reminder",
            notes: arguments.string("notes"),
            dueDate: Self.date(from: arguments.string("dueDateISO"))
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
}
