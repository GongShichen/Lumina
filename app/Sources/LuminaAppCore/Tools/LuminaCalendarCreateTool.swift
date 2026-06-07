import LuminaAgentRuntime
import Foundation
import PersonalMemory

public struct LuminaCalendarCreateTool: LuminaAgentTool {
    public let store: LuminaVolatileCalendarStore

    public init(store: LuminaVolatileCalendarStore) {
        self.store = store
    }

    public var schema: LuminaToolSchema {
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
            outputModalities: [.text, .structuredData],
            idempotencyPolicy: "caller_keyed"
        )
    }

    public func call(arguments: [String: LuminaJSONValue], cancellation: LuminaCancellationToken) async throws -> LuminaToolResult {
        try cancellation.checkCancellation()
        guard let startDate = Self.date(from: arguments.string("startDateISO")) else {
            return Self.failedResult("missing required parameter startDateISO")
        }
        let endDate = Self.date(from: arguments.string("endDateISO")) ?? startDate.addingTimeInterval(1_800)
        guard startDate >= Date().addingTimeInterval(-300) else {
            return Self.failedResult("calendar.create startDateISO is in the past; call device.current_time and recompute a future ISO8601 time.")
        }
        guard endDate > startDate else {
            return Self.failedResult("calendar.create endDateISO must be later than startDateISO.")
        }
        let event = LuminaCalendarEvent(
            title: arguments.string("title") ?? "Lumina 日程",
            startDate: startDate,
            endDate: endDate,
            notes: arguments.string("notes")
        )
        let id = await store.addEvent(event)
        return LuminaToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: [
                "identifier": .string(id),
                "title": .string(event.title),
                "startDateISO": .string(Self.string(from: startDate))
            ],
            content: [.markdown("### 日程已创建\n\n- **\(event.title)**\n- \(startDate.formatted(date: .abbreviated, time: .shortened))")],
            rollbackToken: id
        )
    }

    public func rollback(result: LuminaToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.removeEvent(id: token)
    }

    private static func date(from value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func string(from date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func failedResult(_ message: String) -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "calendar.create",
            status: .failed,
            output: ["summary": .string(message)],
            content: [.text(message)],
            errorMessage: message
        )
    }
}
