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
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        let dueDate = arguments.string("dueDateISO").flatMap(LuminaToolFailureFeedback.parseDate)
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
            output: [
                "identifier": .string(id), "title": .string(reminder.title),
                "dueDateISO": dueDate.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
                "executedArguments": .object(arguments)
            ],
            content: [.text("提醒已创建：\(reminder.title)")],
            rollbackToken: id
        )
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.removeReminder(id: token)
    }

}
