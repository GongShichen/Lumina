import LuminaAgentRuntime
import LuminaAppCore
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
                LuminaToolParameterSchema(name: "startDateISO", type: .dateISO8601, description: "可选查询开始时间，默认当前时间；相对时间任务应先读取 device.current_time 后填入。", required: false),
                LuminaToolParameterSchema(name: "endDateISO", type: .dateISO8601, description: "可选查询结束时间，必须晚于开始时间，默认开始时间后 30 天。", required: false),
                LuminaToolParameterSchema(name: "limit", type: .number, description: "返回数量，1 至 100 的整数，默认 5。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        let parameters: LuminaCalendarSearchParameters
        switch LuminaCalendarSearchParameters.resolve(arguments: arguments, schema: schema) {
        case let .valid(value): parameters = value
        case let .invalid(failure): return failure
        }
        do {
            try await requestCalendarAccess()
        } catch AppToolError.permissionDenied(let reason) {
            return LuminaToolFailureFeedback.enrich(
                LuminaToolResult(callID: UUID(), toolName: schema.name, status: .denied, errorMessage: reason),
                arguments: arguments, schema: schema
            )
        }
        try Task.checkCancellation()
        try cancellation.checkCancellation()
        let query = parameters.query.lowercased()
        let predicate = eventStore.predicateForEvents(withStart: parameters.start, end: parameters.end, calendars: nil)
        let matches = eventStore.events(matching: predicate)
            .filter { query.isEmpty || ($0.title ?? "").lowercased().contains(query) || query.contains("会议") }
            .sorted { $0.startDate < $1.startDate }
        let events = matches.prefix(parameters.limit)
        let summaries = events.map { event in
            let id = event.eventIdentifier ?? event.calendarItemIdentifier
            return "\(event.title ?? "Untitled") [id=\(id)] @ \(event.startDate.formatted(date: .abbreviated, time: .shortened))"
        }
        let items = events.map { event in
            parameters.item(identifier: event.eventIdentifier ?? event.calendarItemIdentifier,
                            title: event.title ?? "Untitled", startDate: event.startDate, endDate: event.endDate)
        }
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: parameters.output(summaries: summaries, items: items, matchedCount: matches.count),
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
            let granted = try await LuminaSystemPermissionRequest.awaitDecision {
                try await self.eventStore.requestFullAccessToEvents()
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
