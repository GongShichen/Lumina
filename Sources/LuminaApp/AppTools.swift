import AgentRuntime
@preconcurrency import EventKit
import Foundation
import PersonalMemory

enum AppToolFactory {
    static func makeTools(
        memoryStore: MemoryStore,
        ledgerStore: LedgerStore,
        subscriptionStore: SubscriptionStore,
        messageDrafts: MessageDraftCenter
    ) -> [AnyAgentTool] {
        [
            MediaImportTool(memoryStore: memoryStore).eraseToAnyTool(),
            LocalSearchTool(memoryStore: memoryStore).eraseToAnyTool(),
            CalendarSearchTool().eraseToAnyTool(),
            ReminderCreateTool().eraseToAnyTool(),
            MessageComposeTool(messageDrafts: messageDrafts).eraseToAnyTool(),
            LedgerRecordTool(store: ledgerStore).eraseToAnyTool(),
            SubscriptionAddTool(store: subscriptionStore, memoryStore: memoryStore).eraseToAnyTool()
        ]
    }
}

private extension AgentTool {
    func eraseToAnyTool() -> AnyAgentTool {
        AnyAgentTool(self)
    }
}

struct LocalSearchTool: AgentTool {
    let memoryStore: MemoryStore

    var schema: ToolSchema {
        ToolSchema(
            name: "local.search",
            description: "搜索端侧 Personal Memory，返回精简摘要和来源。",
            parameters: [
                ToolParameterSchema(name: "query", type: .string, description: "检索问题。"),
                ToolParameterSchema(name: "limit", type: .number, description: "返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let query = arguments.string("query") ?? ""
        let limit = Int(arguments.number("limit") ?? 5)
        let results = try await memoryStore.search(MemorySearchQuery(text: query, limit: limit))
        let summaries = results.map { "\($0.chunk.title): \($0.chunk.summary)" }
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["results": .array(summaries.map(JSONValue.string))],
            content: [.markdown(markdownList(title: "本地检索结果", items: summaries))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到结果。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }
}

struct MediaImportTool: AgentTool {
    let memoryStore: MemoryStore

    var schema: ToolSchema {
        ToolSchema(
            name: "media.import",
            description: "把用户输入的图片、音频、视频或文件作为本地记忆导入，并保留媒体引用。",
            parameters: [
                ToolParameterSchema(name: "note", type: .string, description: "用户对媒体的说明。", required: false, sensitive: true)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .privateData,
            acceptedInputModalities: [.image, .audio, .video, .file, .text, .structuredData],
            outputModalities: [.text, .image, .audio, .video, .file, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .failed,
            errorMessage: "media.import requires request content."
        )
    }

    func call(context: ToolExecutionContext, cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let mediaParts = context.request.content.filter { part in
            part.modality == .image || part.modality == .audio || part.modality == .video || part.modality == .file
        }
        guard !mediaParts.isEmpty else {
            return ToolResult(
                callID: context.call.id,
                toolName: schema.name,
                status: .failed,
                errorMessage: "No media content found in request."
            )
        }

        let note = context.call.arguments.string("note") ?? context.request.text
        let body = ([note] + mediaParts.compactMap(\.textForPlanning)).joined(separator: "\n")
        let document = MemoryDocument(
            source: MemorySource(kind: .imported, identifier: context.request.id.uuidString),
            title: "Imported Media",
            body: body,
            sensitivity: .privateData,
            metadata: [
                "modalities": mediaParts.map(\.modality.rawValue).joined(separator: ",")
            ]
        )
        let chunkIDs = await memoryStore.ingest(document)

        return ToolResult(
            callID: context.call.id,
            toolName: schema.name,
            status: .succeeded,
            output: [
                "importedCount": .number(Double(mediaParts.count)),
                "chunkCount": .number(Double(chunkIDs.count))
            ],
            content: [.markdown("### 媒体已导入\n\n- 附件数：\(mediaParts.count)\n- 写入 chunks：\(chunkIDs.count)")] + mediaParts
        )
    }
}

struct CalendarSearchTool: AgentTool {
    private let eventStore = EKEventStore()

    var schema: ToolSchema {
        ToolSchema(
            name: "calendar.search",
            description: "查询近期日历事件。",
            parameters: [
                ToolParameterSchema(name: "query", type: .string, description: "事件关键词。"),
                ToolParameterSchema(name: "limit", type: .number, description: "返回数量。", required: false)
            ],
            sideEffect: .readOnly,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
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
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["events": .array(events.map(JSONValue.string))],
            content: [.markdown(markdownList(title: "日历事件", items: Array(events)))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到事件。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }

    private func requestCalendarAccess() async throws {
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            return
        }
        let granted = try await eventStore.requestFullAccessToEvents()
        if !granted {
            throw AppToolError.permissionDenied("Calendar full access denied.")
        }
    }
}

struct ReminderCreateTool: AgentTool {
    private let eventStore = EKEventStore()

    var schema: ToolSchema {
        ToolSchema(
            name: "reminder.create",
            description: "创建系统提醒事项。",
            parameters: [
                ToolParameterSchema(name: "title", type: .string, description: "提醒标题。"),
                ToolParameterSchema(name: "notes", type: .string, description: "备注。", required: false, sensitive: true)
            ],
            sideEffect: .systemWrite,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        try await requestReminderAccess()
        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = arguments.string("title") ?? "Agent Reminder"
        reminder.notes = arguments.string("notes")
        reminder.calendar = eventStore.defaultCalendarForNewReminders()
        try eventStore.save(reminder, commit: true)
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(reminder.calendarItemIdentifier)],
            content: [.text("提醒已创建：\(reminder.title ?? "Agent Reminder")")],
            rollbackToken: reminder.calendarItemIdentifier
        )
    }

    func rollback(result: ToolResult) async -> Bool {
        guard let identifier = result.rollbackToken,
              let reminder = eventStore.calendarItem(withIdentifier: identifier) as? EKReminder else {
            return false
        }
        do {
            try eventStore.remove(reminder, commit: true)
            return true
        } catch {
            return false
        }
    }

    private func requestReminderAccess() async throws {
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            return
        }
        let granted = try await eventStore.requestFullAccessToReminders()
        if !granted {
            throw AppToolError.permissionDenied("Reminder full access denied.")
        }
    }
}

struct MessageComposeTool: AgentTool {
    let messageDrafts: MessageDraftCenter

    var schema: ToolSchema {
        ToolSchema(
            name: "message.compose",
            description: "创建短信草稿并打开系统消息编辑器，由用户手动发送或取消。",
            parameters: [
                ToolParameterSchema(name: "recipient", type: .string, description: "收件人。", required: false, sensitive: true),
                ToolParameterSchema(name: "body", type: .string, description: "短信正文。", sensitive: true)
            ],
            sideEffect: .externalCommunication,
            sensitivity: .privateData,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let recipient = arguments.string("recipient").map { [$0] } ?? []
        let body = arguments.string("body") ?? ""
        await messageDrafts.publish(MessageDraft(recipients: recipient, body: body))
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["draft": .string("Message composer opened.")],
            content: [.text("短信编辑器已打开，等待用户发送或取消。")]
        )
    }
}

struct LedgerRecordTool: AgentTool {
    let store: LedgerStore

    var schema: ToolSchema {
        ToolSchema(
            name: "ledger.record",
            description: "记录 App 本地记账条目。",
            parameters: [
                ToolParameterSchema(name: "memo", type: .string, description: "交易说明。", sensitive: true),
                ToolParameterSchema(name: "amount", type: .number, description: "金额。", required: false)
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .sensitive,
            acceptedInputModalities: [.text, .image, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let transaction = LedgerTransaction(
            memo: arguments.string("memo") ?? "Agent ledger item",
            amount: arguments.number("amount").map { Decimal($0) }
        )
        let id = await store.append(transaction)
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id)],
            content: [.text("记账已保存：\(transaction.memo)")],
            rollbackToken: id
        )
    }

    func rollback(result: ToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}

struct SubscriptionAddTool: AgentTool {
    let store: SubscriptionStore
    let memoryStore: MemoryStore

    var schema: ToolSchema {
        ToolSchema(
            name: "subscription.add",
            description: "添加内容订阅，并写入本地记忆索引。",
            parameters: [
                ToolParameterSchema(name: "source", type: .string, description: "RSS 或 URL。")
            ],
            sideEffect: .appLocalWrite,
            sensitivity: .normal,
            acceptedInputModalities: [.text, .file, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let source = arguments.string("source") ?? ""
        let subscription = ContentSubscription(source: source)
        let id = await store.add(subscription)
        await memoryStore.ingest(MemoryDocument(
            source: MemorySource(kind: .subscription, identifier: id),
            title: "Subscription",
            body: source,
            sensitivity: .normal
        ))
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id)],
            content: [.text("订阅已添加：\(source)")],
            rollbackToken: id
        )
    }

    func rollback(result: ToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}

enum AppToolError: LocalizedError {
    case permissionDenied(String)

    var errorDescription: String? {
        switch self {
        case let .permissionDenied(message):
            return message
        }
    }
}
