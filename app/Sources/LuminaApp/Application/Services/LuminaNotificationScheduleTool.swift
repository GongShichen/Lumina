import LuminaAgentRuntime
import LuminaAppCore
import Foundation
import UserNotifications

struct LuminaNotificationScheduleTool: LuminaAgentTool {
    var schema: LuminaToolSchema {
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

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        do {
            try await requestNotificationAccess()
        } catch AppToolError.permissionDenied(let reason) {
            return LuminaToolFailureFeedback.enrich(
                LuminaToolResult(callID: UUID(), toolName: schema.name, status: .denied, errorMessage: reason),
                arguments: arguments, schema: schema
            )
        }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        if let failure = LuminaToolFailureFeedback.validateScheduledWrite(schema: schema, arguments: arguments) { return failure }
        let fireDate = arguments.string("dateISO").flatMap(LuminaToolFailureFeedback.parseDate)
            ?? Date().addingTimeInterval(arguments.number("timeIntervalSeconds")!)
        let title = arguments.string("title") ?? "Lumina 提醒"
        let body = arguments.string("body") ?? title
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        try await UNUserNotificationCenter.current().add(request)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(identifier),
                "title": .string(title),
                "fireDate": .string(ISO8601DateFormatter().string(from: fireDate)),
                "executedArguments": .object(arguments)
            ],
            content: [.markdown("## 通知已安排\n\n\(title)")]
        )
    }

    private func requestNotificationAccess() async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            return
        case .notDetermined:
            let granted = try await LuminaSystemPermissionRequest.awaitDecision {
                try await center.requestAuthorization(options: [.alert, .sound])
            }
            if !granted {
                throw AppToolError.permissionDenied("通知权限未开启。请在系统设置中允许 Lumina 发送通知后重试。")
            }
        case .denied:
            throw AppToolError.permissionDenied("通知权限已被拒绝。请在系统设置中允许 Lumina 发送通知后重试。")
        @unknown default:
            throw AppToolError.permissionDenied("当前系统无法确认通知权限，请检查设置后重试。")
        }
    }

}
