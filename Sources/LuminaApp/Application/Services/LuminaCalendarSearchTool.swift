import AgentRuntime
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
                LuminaToolParameterSchema(name: "query", type: .string, description: "事件关键词。"),
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
        let end = Calendar.current.date(byAdding: .day, value: 30, to: now) ?? now
        let predicate = eventStore.predicateForEvents(withStart: now, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)
            .filter { query.isEmpty || $0.title.lowercased().contains(query) || query.contains("会议") }
            .prefix(limit)
            .map { event in
                "\(event.title ?? "Untitled") @ \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
            }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["events": .array(events.map(LuminaJSONValue.string))],
            content: [.markdown(markdownList(title: "日历事件", items: Array(events)))]
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
}
