import LuminaAgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

final class LuminaCalendarSearchTool: LuminaAgentTool, @unchecked Sendable {
    private let eventStore = EKEventStore()

    var schema: LuminaToolSchema {
        LuminaToolSchema(
            name: "calendar.search",
            description: "查询近期日历事件。",
            parameters: [
                LuminaToolParameterSchema(name: "query", type: .string, description: "事件关键词；为空时返回近期事件。", required: false),
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "可选查询开始时间；相对时间任务应先读取 device.current_time 后填入。", required: false),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "可选查询结束时间。", required: false),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        try await requestCalendarAccess()
        let query = arguments.string("query")?.lowercased() ?? ""
        let limit = Int(arguments.number("limit") ?? 5)
        let now = Date()
        let start = Self.date(from: arguments.string("startDateISO")) ?? now
        let end = Self.date(from: arguments.string("endDateISO"))
            ?? Calendar.current.date(byAdding: .day, value: 30, to: start)
            ?? start
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { query.isEmpty || $0.title.lowercased().contains(query) || query.contains("会议") }
            .prefix(limit)
        let summaries = events.map { event in
            let id = event.eventIdentifier ?? event.calendarItemIdentifier
            return "\(event.title ?? "Untitled") [id=\(id)] @ \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
        }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["events": .array(summaries.map(LuminaJSONValue.string))],
            content: [.markdown(markdownList(title: "日历事件", items: Array(summaries)))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到事件。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
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
            throw AppToolError.permissionDenied("当前设备限制了日历访问，Lumina 无法读取日程。")
        case .writeOnly:
            throw AppToolError.permissionDenied("当前只有日历写入权限，查询日程需要完整访问权限。请到系统设置中允许完整访问。")
        @unknown default:
            throw AppToolError.permissionDenied("当前日历权限状态不可用。")
        }
    }

    private static func date(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }
}
