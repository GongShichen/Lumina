import LuminaAgentRuntime
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
        try await requestNotificationAccess()
        let title = arguments.string("title") ?? "Lumina 提醒"
        let body = arguments.string("body") ?? title
        let fireDate = Self.fireDate(arguments: arguments)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireDate.timeIntervalSinceNow), repeats: false)
        let identifier = UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await UNUserNotificationCenter.current().add(request)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(identifier),
                "title": .string(title),
                "fireDate": .string(ISO8601DateFormatter().string(from: fireDate))
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
            let granted = try await LuminaPermissionTimingRecorder.shared.record {
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
