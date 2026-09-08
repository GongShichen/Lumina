import LuminaAgentRuntime
import Foundation

public struct LuminaNotificationScheduleTool: LuminaAgentTool {
    public let store: LuminaScheduledNotificationStore

    public init(store: LuminaScheduledNotificationStore = LuminaScheduledNotificationStore()) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "notification.schedule",
            description: "创建 App 本地通知。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "通知标题。"),
                LuminaToolParameterSchema(name: "body", type: .string, description: "通知正文。", required: false),
                LuminaToolParameterSchema(name: "dateISO", type: .dateISO8601, description: "触发时间。", required: false),
                LuminaToolParameterSchema(name: "timeIntervalSeconds", type: .number, description: "相对触发秒数。", required: false)
            ],
            sideEffect: .systemWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData],
            idempotencyPolicy: "caller_keyed"
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        let title = arguments.string("title") ?? "Lumina 提醒"
        let body = arguments.string("body") ?? title
        let fireDate = arguments.string("dateISO").flatMap(LuminaToolFailureFeedback.parseDate)
            ?? Date().addingTimeInterval(arguments.number("timeIntervalSeconds")!)
        let notification = LuminaScheduledNotification(title: title, body: body, fireDate: fireDate)
        await store.append(notification)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(notification.id),
                "title": .string(title),
                "fireDate": .string(ISO8601DateFormatter().string(from: fireDate)),
                "executedArguments": .object(arguments)
            ],
            content: [.markdown("## 通知已安排\n\n\(title)")]
        )
    }

}
