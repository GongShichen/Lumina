import LuminaAgentClient
@preconcurrency import EventKit
import Foundation
import PersonalMemory

final class LuminaCalendarCreateTool: LuminaAgentTool, @unchecked Sendable {
    private let eventStore = EKEventStore()

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "calendar.create",
            description: "创建系统日历事件。",
            parameters: [
                LuminaToolParameterSchema(name: "title", type: .string, description: "事件标题。"),
                LuminaToolParameterSchema(name: "startDateISO", type: .string, description: "ISO8601 开始时间。"),
                LuminaToolParameterSchema(name: "endDateISO", type: .string, description: "ISO8601 结束时间。", required: false),
                LuminaToolParameterSchema(name: "notes", type: .string, description: "备注。", required: false, sensitive: true)
            ],
            sideEffect: .systemWrite,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        try await requestCalendarAccess()
        let startDate = Self.date(from: arguments.string("startDateISO")) ?? Date().addingTimeInterval(3_600)
        let endDate = Self.date(from: arguments.string("endDateISO")) ?? startDate.addingTimeInterval(1_800)
        let event = EKEvent(eventStore: eventStore)
        event.title = arguments.string("title") ?? "Lumina 日程"
        event.notes = arguments.string("notes")
        event.startDate = startDate
        event.endDate = endDate
        event.calendar = eventStore.defaultCalendarForNewEvents
        try eventStore.save(event, span: .thisEvent, commit: true)
        let identifier = event.eventIdentifier ?? event.calendarItemIdentifier
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(identifier),
                "title": .string(event.title ?? "Lumina 日程"),
                "startDateISO": .string(Self.string(from: startDate))
            ],
            content: [.markdown("### 日程已创建\n\n- **\(event.title ?? "Lumina 日程")**\n- \(startDate.formatted(date: .abbreviated, time: .shortened))")],
            rollbackToken: identifier
        )
    }

    func rollback(result: LuminaToolResult) async -> Bool {
        guard let identifier = result.rollbackToken,
              let event = eventStore.event(withIdentifier: identifier) ?? eventStore.calendarItem(withIdentifier: identifier) as? EKEvent else {
            return false
        }
        do {
            try eventStore.remove(event, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }

    private func requestCalendarAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await LuminaSystemPermissionRequest.withTimeout {
                try await LuminaPermissionTimingRecorder.shared.record {
                    try await self.eventStore.requestFullAccessToEvents()
                }
            }
            if granted {
                return
            }
            throw AppToolError.permissionDenied("你没有授予日历完整访问权限。请允许 Lumina 访问日历后再试。")
        case .denied:
            throw AppToolError.permissionDenied("日历权限已被拒绝。请到系统设置中允许 Lumina 访问日历。")
        case .restricted:
            throw AppToolError.permissionDenied("当前设备限制了日历访问，Lumina 无法创建日程。")
        case .writeOnly:
            throw AppToolError.permissionDenied("当前只有日历写入权限。Lumina 需要完整访问来创建并保存可回滚的事件标识。")
        @unknown default:
            throw AppToolError.permissionDenied("当前日历权限状态不可用。")
        }
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
