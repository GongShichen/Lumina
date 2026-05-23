import AgentRuntime
import Foundation
import PersonalMemory

public enum AppCoreToolFactory {
    public static func makeTools(
        memoryStore: MemoryStore,
        ledgerStore: LedgerStore,
        subscriptionStore: SubscriptionStore,
        messageDrafts: MessageDraftCenter,
        calendarStore: InMemoryCalendarStore = InMemoryCalendarStore()
    ) -> [AnyAgentTool] {
        [
            MediaImportTool(memoryStore: memoryStore).eraseToAnyTool(),
            LocalSearchTool(memoryStore: memoryStore).eraseToAnyTool(),
            CalendarSearchTool(store: calendarStore).eraseToAnyTool(),
            ReminderCreateTool(store: calendarStore).eraseToAnyTool(),
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

public struct CalendarEvent: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var startDate: Date

    public init(id: UUID = UUID(), title: String, startDate: Date = Date()) {
        self.id = id
        self.title = title
        self.startDate = startDate
    }
}

public struct ReminderItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String?

    public init(id: UUID = UUID(), title: String, notes: String? = nil) {
        self.id = id
        self.title = title
        self.notes = notes
    }
}

public actor InMemoryCalendarStore {
    private var events: [CalendarEvent]
    private var reminders: [ReminderItem] = []

    public init(events: [CalendarEvent] = []) {
        self.events = events
    }

    public func searchEvents(query: String, limit: Int) -> [CalendarEvent] {
        let lowered = query.lowercased()
        return events
            .filter { lowered.isEmpty || $0.title.lowercased().contains(lowered) || lowered.contains("会议") }
            .sorted { $0.startDate < $1.startDate }
            .prefix(limit)
            .map { $0 }
    }

    public func addReminder(_ reminder: ReminderItem) -> String {
        reminders.append(reminder)
        return reminder.id.uuidString
    }

    public func removeReminder(id: String) -> Bool {
        guard let uuid = UUID(uuidString: id) else { return false }
        let before = reminders.count
        reminders.removeAll { $0.id == uuid }
        return reminders.count < before
    }

    public func allReminders() -> [ReminderItem] {
        reminders
    }
}

public struct LocalSearchTool: AgentTool {
    public let memoryStore: MemoryStore

    public init(memoryStore: MemoryStore) {
        self.memoryStore = memoryStore
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
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

public struct MediaImportTool: AgentTool {
    public let memoryStore: MemoryStore

    public init(memoryStore: MemoryStore) {
        self.memoryStore = memoryStore
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        return ToolResult(callID: UUID(), toolName: schema.name, status: .failed, errorMessage: "media.import requires request content.")
    }

    public func call(context: ToolExecutionContext, cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let mediaParts = context.request.content.filter { [.image, .audio, .video, .file].contains($0.modality) }
        guard !mediaParts.isEmpty else {
            return ToolResult(callID: context.call.id, toolName: schema.name, status: .failed, errorMessage: "No media content found in request.")
        }
        let note = context.call.arguments.string("note") ?? context.request.text
        let body = ([note] + mediaParts.compactMap(\.textForPlanning)).joined(separator: "\n")
        let chunkIDs = await memoryStore.ingest(MemoryDocument(
            source: MemorySource(kind: .imported, identifier: context.request.id.uuidString),
            title: "Imported Media",
            body: body,
            sensitivity: .privateData,
            metadata: ["modalities": mediaParts.map(\.modality.rawValue).joined(separator: ",")]
        ))
        return ToolResult(
            callID: context.call.id,
            toolName: schema.name,
            status: .succeeded,
            output: ["chunkCount": .number(Double(chunkIDs.count))],
            content: [.markdown("### 媒体已导入\n\n- 附件数：\(mediaParts.count)\n- 写入 chunks：\(chunkIDs.count)")] + mediaParts
        )
    }
}

public struct CalendarSearchTool: AgentTool {
    public let store: InMemoryCalendarStore

    public init(store: InMemoryCalendarStore) {
        self.store = store
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let events = await store.searchEvents(query: arguments.string("query") ?? "", limit: Int(arguments.number("limit") ?? 5))
        let summaries = events.map { "\($0.title) @ \($0.startDate.formatted(date: .abbreviated, time: .shortened))" }
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["events": .array(summaries.map(JSONValue.string))],
            content: [.markdown(markdownList(title: "日历事件", items: summaries))]
        )
    }

    private func markdownList(title: String, items: [String]) -> String {
        guard !items.isEmpty else { return "### \(title)\n\n没有找到事件。" }
        return "### \(title)\n\n" + items.map { "- \($0)" }.joined(separator: "\n")
    }
}

public struct ReminderCreateTool: AgentTool {
    public let store: InMemoryCalendarStore

    public init(store: InMemoryCalendarStore) {
        self.store = store
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let reminder = ReminderItem(
            title: arguments.string("title") ?? "Agent Reminder",
            notes: arguments.string("notes")
        )
        let id = await store.addReminder(reminder)
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["identifier": .string(id)],
            content: [.text("提醒已创建：\(reminder.title)")],
            rollbackToken: id
        )
    }

    public func rollback(result: ToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.removeReminder(id: token)
    }
}

public struct MessageComposeTool: AgentTool {
    public let messageDrafts: MessageDraftCenter

    public init(messageDrafts: MessageDraftCenter) {
        self.messageDrafts = messageDrafts
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        await messageDrafts.publish(MessageDraft(
            recipients: arguments.string("recipient").map { [$0] } ?? [],
            body: arguments.string("body") ?? ""
        ))
        return ToolResult(
            callID: UUID(),
            toolName: schema.name,
            status: .succeeded,
            output: ["draft": .string("Message composer opened.")],
            content: [.text("短信编辑器已打开，等待用户发送或取消。")]
        )
    }
}

public struct LedgerRecordTool: AgentTool {
    public let store: LedgerStore

    public init(store: LedgerStore) {
        self.store = store
    }

    public var schema: ToolSchema {
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

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
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

    public func rollback(result: ToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}

public struct SubscriptionAddTool: AgentTool {
    public let store: SubscriptionStore
    public let memoryStore: MemoryStore

    public init(store: SubscriptionStore, memoryStore: MemoryStore) {
        self.store = store
        self.memoryStore = memoryStore
    }

    public var schema: ToolSchema {
        ToolSchema(
            name: "subscription.add",
            description: "添加内容订阅，并写入本地记忆索引。",
            parameters: [ToolParameterSchema(name: "source", type: .string, description: "RSS 或 URL。")],
            sideEffect: .appLocalWrite,
            sensitivity: .normal,
            acceptedInputModalities: [.text, .file, .structuredData],
            outputModalities: [.text, .structuredData]
        )
    }

    public func call(arguments: [String: JSONValue], cancellation: CancellationToken) async throws -> ToolResult {
        try cancellation.checkCancellation()
        let source = arguments.string("source") ?? ""
        let id = await store.add(ContentSubscription(source: source))
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

    public func rollback(result: ToolResult) async -> Bool {
        guard let token = result.rollbackToken else { return false }
        return await store.remove(id: token)
    }
}
