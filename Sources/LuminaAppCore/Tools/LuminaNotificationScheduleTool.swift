import AgentRuntime
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
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let title = arguments.string("title") ?? "Lumina 提醒"
        let body = arguments.string("body") ?? title
        let fireDate = Self.fireDate(arguments: arguments)
        let notification = LuminaScheduledNotification(title: title, body: body, fireDate: fireDate)
        await store.append(notification)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(notification.id),
                "title": .string(title),
                "fireDate": .string(ISO8601DateFormatter().string(from: fireDate))
            ],
            content: [.markdown("## 通知已安排\n\n\(title)")]
        )
    }

    private static func fireDate(arguments: [String: LuminaJSONValue]) -> Date {
        if let iso = arguments.string("dateISO"),
           let date = ISO8601DateFormatter().date(from: iso) {
            return date
        }
        if let interval = arguments.number("timeIntervalSeconds") {
            return Date().addingTimeInterval(max(1, interval))
        }
        return Date().addingTimeInterval(1_800)
    }
}
