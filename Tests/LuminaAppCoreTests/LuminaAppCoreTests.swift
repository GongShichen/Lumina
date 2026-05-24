import XCTest
import AgentRuntime
@testable import LuminaAppCore
@testable import PersonalMemory

final class LuminaAppCoreTests: XCTestCase {
    func testCurrentTimeToolReturnsRealDeviceTimeSnapshot() async throws {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let fixedDate = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 5,
            day: 24,
            hour: 13,
            minute: 30,
            second: 0
        ))!
        let tool = LuminaCurrentTimeTool(
            now: { fixedDate },
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            timeZone: timeZone
        )

        let result = try await tool.call(arguments: [:], cancellation: LuminaCancellationToken())

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.toolName, "device.current_time")
        XCTAssertEqual(result.output.string("dayPeriod"), "下午")
        XCTAssertEqual(result.output.number("hour"), 13)
        XCTAssertEqual(result.output.string("timeZoneIdentifier"), "Asia/Shanghai")
        XCTAssertTrue(result.content.contains { ($0.textForPlanning ?? "").contains("本机时间") })
    }

    func testFactoryIncludesCurrentTimeTool() async {
        let tools = LuminaAppCoreToolFactory.makeTools(
            memoryStore: LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false)),
            ledgerStore: LuminaLedgerStore(),
            subscriptionStore: LuminaSubscriptionStore(),
            messageDrafts: LuminaMessageDraftCenter()
        )
        let schemas = tools.map(\.schema)

        XCTAssertTrue(schemas.contains { $0.name == "device.current_time" && $0.sideEffect == .readOnly })
        XCTAssertTrue(schemas.contains { $0.name == "calendar.create" && $0.sideEffect == .systemWrite })
        XCTAssertTrue(schemas.contains { $0.name == "contacts.search" && $0.sideEffect == .readOnly })
        XCTAssertTrue(schemas.contains { $0.name == "location.current" && $0.sideEffect == .readOnly })
        XCTAssertTrue(schemas.contains { $0.name == "notification.schedule" && $0.sideEffect == .systemWrite })
        XCTAssertTrue(schemas.contains { $0.name == "clipboard.read" && $0.sideEffect == .readOnly })
        XCTAssertTrue(schemas.contains { $0.name == "file.save_note" && $0.sideEffect == .appLocalWrite })
        XCTAssertTrue(schemas.contains { $0.name == "url.open" && $0.sideEffect == .externalCommunication })
        XCTAssertTrue(schemas.contains { $0.name == "memory.ingest_text" && $0.sideEffect == .appLocalWrite })
        XCTAssertTrue(schemas.contains { $0.name == "ledger.search" && $0.sideEffect == .readOnly })
        XCTAssertTrue(schemas.contains { $0.name == "ask_user" && $0.sideEffect == .readOnly })
    }

    func testFactoryIncludesExtendedAssistantToolsButNotAppRuntimeCapabilities() async {
        let tools = LuminaAppCoreToolFactory.makeTools(
            memoryStore: LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false)),
            ledgerStore: LuminaLedgerStore(),
            subscriptionStore: LuminaSubscriptionStore(),
            messageDrafts: LuminaMessageDraftCenter()
        )
        let names = Set(tools.map(\.schema.name))

        [
            "calendar.update",
            "calendar.delete",
            "calendar.availability",
            "reminder.search",
            "reminder.update",
            "reminder.complete",
            "reminder.delete",
            "contacts.create",
            "contacts.update",
            "contacts.open",
            "email.compose",
            "phone.call",
            "maps.search",
            "maps.route",
            "clipboard.write",
            "share.prepare",
            "app.open_settings",
            "memory.recent",
            "memory.stats",
            "memory.delete",
            "ledger.summary",
            "ledger.update",
            "ledger.delete",
            "subscription.list",
            "subscription.refresh",
            "subscription.remove",
            "file.list_notes",
            "file.read_note",
            "file.update_note",
            "file.delete_note",
            "webpage.fetch_text",
            "webpage.save_to_memory",
            "document.read_text",
            "image.extract_text",
            "image.describe_metadata",
            "calculator.evaluate",
            "text.transform",
            "device.power_status",
            "network.status",
            "storage.status",
            "weather.current",
            "weather.forecast",
            "health.summary",
            "health.query_samples"
        ].forEach { name in
            XCTAssertTrue(names.contains(name), "Missing \(name)")
        }
        XCTAssertFalse(names.contains("voice.input"))
        XCTAssertFalse(names.contains("live_activity.start"))
        XCTAssertFalse(names.contains("dynamic_island.update"))
    }

    func testExtendedToolsUseRealStoresAndFiles() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-extended-\(UUID().uuidString)", isDirectory: true)
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let ledger = LuminaLedgerStore()
        let subscriptions = LuminaSubscriptionStore()
        let calendar = LuminaVolatileCalendarStore()
        _ = await ledger.append(LuminaLedgerTransaction(memo: "咖啡", amount: Decimal(42)))
        _ = await memory.ingest(LuminaMemoryDocument(source: LuminaMemorySource(kind: .appNote, identifier: "test"), title: "记忆", body: "Lumina extended tool test"))
        let tools = LuminaExtendedToolCatalog.makeTools(
            memoryStore: memory,
            ledgerStore: ledger,
            subscriptionStore: subscriptions,
            calendarStore: calendar,
            documentsDirectory: directory,
            openURL: { _ in true }
        )
        let byName = Dictionary(uniqueKeysWithValues: tools.map { ($0.schema.name, $0) })

        let updateNote = try await XCTUnwrap(byName["file.update_note"]).call(arguments: [
            "filename": .string("daily.md"),
            "body": .string("今天完成 tool 扩展")
        ], cancellation: LuminaCancellationToken())
        let readNote = try await XCTUnwrap(byName["file.read_note"]).call(arguments: [
            "filename": .string("daily.md")
        ], cancellation: LuminaCancellationToken())
        let memoryStats = try await XCTUnwrap(byName["memory.stats"]).call(arguments: [:], cancellation: LuminaCancellationToken())
        let ledgerSummary = try await XCTUnwrap(byName["ledger.summary"]).call(arguments: [:], cancellation: LuminaCancellationToken())
        let calculator = try await XCTUnwrap(byName["calculator.evaluate"]).call(arguments: [
            "expression": .string("2+3*4")
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(updateNote.status, .succeeded)
        XCTAssertEqual(readNote.status, .succeeded)
        XCTAssertEqual(memoryStats.output.number("chunkCount"), 1)
        XCTAssertEqual(ledgerSummary.output.number("count"), 1)
        XCTAssertEqual(calculator.output.number("result"), 14)
        try? FileManager.default.removeItem(at: directory)
    }

    func testAskUserToolSchemaAndSuccessfulAnswer() async throws {
        let tool = LuminaAskUserTool { request in
            LuminaAskUserResponse(
                requestID: request.id,
                answers: [
                    LuminaAskUserAnswer(questionID: "style", choiceID: "focused", value: "专注优先")
                ]
            )
        }

        let result = try await tool.call(arguments: [
            "reason": .string("需要确认偏好"),
            "questions": .array([
                .object([
                    "id": .string("style"),
                    "header": .string("偏好"),
                    "question": .string("你想按哪种方式安排？"),
                    "options": .array([
                        .object([
                            "id": .string("focused"),
                            "label": .string("专注优先"),
                            "description": .string("先安排深度工作"),
                            "recommended": .bool(true)
                        ]),
                        .object([
                            "id": .string("balanced"),
                            "label": .string("均衡安排"),
                            "description": .string("工作休息平衡")
                        ])
                    ])
                ])
            ])
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(tool.schema.name, "ask_user")
        XCTAssertEqual(tool.schema.sideEffect, .readOnly)
        XCTAssertEqual(result.status, .succeeded)
        guard case let .array(answers)? = result.output["answers"] else {
            return XCTFail("Expected answers array")
        }
        XCTAssertEqual(answers.count, 1)
        XCTAssertTrue(result.content.contains { ($0.textForPlanning ?? "").contains("已收到你的回答") })
    }

    func testAskUserToolCanPauseAndResumeThroughCoordinatorClosure() async throws {
        let probe = AskUserProbe()
        let tool = LuminaAskUserTool { request in
            await probe.waitForAnswer(request)
        }

        let task = Task {
            try await tool.call(arguments: [
                "reason": .string("需要用户补充"),
                "questions": .array([
                    .object([
                        "id": .string("scope"),
                        "header": .string("范围"),
                        "question": .string("安排哪个时间段？"),
                        "options": .array([
                            .object(["id": .string("today"), "label": .string("今天"), "description": .string("今天剩余时间")]),
                            .object(["id": .string("tomorrow"), "label": .string("明天"), "description": .string("明天全天")])
                        ])
                    ])
                ])
            ], cancellation: LuminaCancellationToken())
        }

        try await waitUntil { await probe.hasPendingRequest() }
        await probe.answer(with: [LuminaAskUserAnswer(questionID: "scope", choiceID: "tomorrow", value: "明天")])
        let result = try await task.value

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.output.bool("cancelled"), false)
    }

    func testAskUserToolCancelledResponseStopsAsCancelledResult() async throws {
        let tool = LuminaAskUserTool { request in
            LuminaAskUserResponse(requestID: request.id, answers: [], cancelled: true)
        }

        let result = try await tool.call(arguments: [
            "reason": .string("需要确认"),
            "questions": .array([
                .object([
                    "id": .string("q"),
                    "header": .string("确认"),
                    "question": .string("是否继续？"),
                    "options": .array([
                        .object(["id": .string("yes"), "label": .string("继续"), "description": .string("继续处理")]),
                        .object(["id": .string("later"), "label": .string("稍后"), "description": .string("暂停处理")])
                    ])
                ])
            ])
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(result.status, .cancelled)
        XCTAssertEqual(result.output.bool("cancelled"), true)
    }

    func testTemporalParserParsesChineseRelativeSchedule() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(timeZone: timeZone, year: 2026, month: 5, day: 24, hour: 9, minute: 58))!

        let parsed = LuminaTemporalParser.parseScheduleIntent("我十分钟后要出门，给我定一个日程", now: now, calendar: calendar)

        XCTAssertEqual(parsed.title, "出门")
        XCTAssertEqual(calendar.dateComponents([.minute], from: now, to: parsed.startDate).minute, 10)
    }

    func testTemporalParserParsesTomorrowMorningReminderTitle() {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let now = calendar.date(from: DateComponents(timeZone: timeZone, year: 2026, month: 5, day: 24, hour: 13, minute: 36))!

        let parsed = LuminaTemporalParser.parseScheduleIntent("帮我创建一个明天上午7点的提醒，去上厕所", now: now, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: parsed.startDate)

        XCTAssertEqual(parsed.title, "去上厕所")
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 25)
        XCTAssertEqual(components.hour, 7)
        XCTAssertEqual(components.minute, 0)
    }

    func testHomeGreetingRequestUsesPlannerSelectedCurrentTimeToolThroughRuntime() async {
        var calendar = Calendar(identifier: .gregorian)
        let timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar.timeZone = timeZone
        let fixedDate = calendar.date(from: DateComponents(
            timeZone: timeZone,
            year: 2026,
            month: 5,
            day: 24,
            hour: 22,
            minute: 0,
            second: 0
        ))!
        let timeTool = LuminaCurrentTimeTool(now: { fixedDate }, calendar: calendar, locale: Locale(identifier: "zh_CN"), timeZone: timeZone)
        let runtime = LuminaAgentRuntime(
            tools: [timeTool.eraseToAnyTool()],
            reactPlanner: LuminaFixedReActPlanner(calls: [
                LuminaToolCall(toolName: "device.current_time", arguments: [:])
            ])
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "启动首页时生成问候语，请读取本机时间"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "device.current_time" })
        XCTAssertEqual(result.toolResults.first?.output.string("dayPeriod"), "晚上")
    }

    func testMessageComposeOnlyPublishesDraft() async throws {
        let drafts = LuminaMessageDraftCenter()
        let tool = LuminaMessageComposeTool(messageDrafts: drafts)

        let result = try await tool.call(arguments: [
            "recipient": .string("Alex"),
            "body": .string("Lunch?")
        ], cancellation: LuminaCancellationToken())

        let allDrafts = await drafts.allDrafts()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(allDrafts.first?.recipients, ["Alex"])
        XCTAssertEqual(allDrafts.first?.body, "Lunch?")
    }

    func testLedgerRollback() async throws {
        let store = LuminaLedgerStore()
        let tool = LuminaLedgerRecordTool(store: store)
        let result = try await tool.call(arguments: ["memo": .string("coffee"), "amount": .number(42)], cancellation: LuminaCancellationToken())

        let countBeforeRollback = await store.allTransactions().count
        let didRollback = await tool.rollback(result: result)
        let countAfterRollback = await store.allTransactions().count
        XCTAssertEqual(countBeforeRollback, 1)
        XCTAssertTrue(didRollback)
        XCTAssertEqual(countAfterRollback, 0)
    }

    func testLedgerStorePersistsTransactions() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-ledger-\(UUID().uuidString)")
            .appendingPathComponent("ledger.json")
        let store = LuminaLedgerStore(url: url)
        _ = await store.append(LuminaLedgerTransaction(memo: "真实账目", amount: Decimal(18)))

        let restored = LuminaLedgerStore(url: url)
        try await restored.load()
        let transactions = await restored.allTransactions()

        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.memo, "真实账目")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testLedgerSearchReadsRealStoreEntries() async throws {
        let store = LuminaLedgerStore()
        _ = await store.append(LuminaLedgerTransaction(memo: "咖啡", amount: Decimal(42)))
        _ = await store.append(LuminaLedgerTransaction(memo: "午饭", amount: Decimal(58)))
        let tool = LuminaLedgerSearchTool(store: store)

        let result = try await tool.call(arguments: ["query": .string("咖啡")], cancellation: LuminaCancellationToken())

        XCTAssertEqual(result.status, .succeeded)
        guard case let .array(transactions)? = result.output["transactions"] else {
            return XCTFail("Expected transactions array")
        }
        XCTAssertEqual(transactions.count, 1)
    }

    func testMemoryIngestTextWritesSearchableMemory() async throws {
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let tool = LuminaMemoryIngestTextTool(memoryStore: memory)

        let result = try await tool.call(arguments: [
            "title": .string("真实记忆"),
            "body": .string("明天下午处理 Lumina 工程验收")
        ], cancellation: LuminaCancellationToken())
        let matches = try await memory.search(LuminaMemorySearchQuery(text: "Lumina 工程验收", limit: 5))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertFalse(matches.isEmpty)
    }

    func testFileSaveNoteWritesMarkdownFile() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-note-\(UUID().uuidString)", isDirectory: true)
        let tool = LuminaFileSaveNoteTool(documentsDirectory: directory)

        let result = try await tool.call(arguments: [
            "title": .string("验收记录"),
            "body": .string("真机测试待执行")
        ], cancellation: LuminaCancellationToken())

        XCTAssertEqual(result.status, .succeeded)
        let filename = try XCTUnwrap(result.output.string("filename"))
        let fileURL = directory.appendingPathComponent("Lumina Notes").appendingPathComponent(filename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        try? FileManager.default.removeItem(at: directory)
    }

    func testInjectedReadToolsReturnRealProviderValues() async throws {
        let contacts = LuminaContactsSearchTool { query, _ in
            [LuminaContactSearchResult(name: query, phones: ["123"], emails: ["a@example.com"])]
        }
        let location = LuminaLocationCurrentTool {
            LuminaLocationSnapshot(latitude: 31.2, longitude: 121.5, horizontalAccuracy: 20, locality: "上海")
        }
        let clipboard = LuminaClipboardReadTool {
            "https://example.com"
        }

        let contactResult = try await contacts.call(arguments: ["query": .string("Alex")], cancellation: LuminaCancellationToken())
        let locationResult = try await location.call(arguments: [:], cancellation: LuminaCancellationToken())
        let clipboardResult = try await clipboard.call(arguments: [:], cancellation: LuminaCancellationToken())

        XCTAssertEqual(contactResult.status, .succeeded)
        XCTAssertEqual(locationResult.output.string("locality"), "上海")
        XCTAssertEqual(clipboardResult.output.string("text"), "https://example.com")
    }

    func testNotificationAndURLOpenToolsUseRealStoresAndCallbacks() async throws {
        let notificationStore = LuminaScheduledNotificationStore()
        let notificationTool = LuminaNotificationScheduleTool(store: notificationStore)
        let openedURLs = CapturedURLStore()
        let urlTool = LuminaURLOpenTool { url in
            await openedURLs.record(url)
            return true
        }

        let notificationResult = try await notificationTool.call(arguments: [
            "title": .string("出门"),
            "timeIntervalSeconds": .number(60)
        ], cancellation: LuminaCancellationToken())
        let urlResult = try await urlTool.call(arguments: [
            "kind": .string("map"),
            "query": .string("咖啡")
        ], cancellation: LuminaCancellationToken())

        let notifications = await notificationStore.all()
        let opened = await openedURLs.all()
        XCTAssertEqual(notificationResult.status, .succeeded)
        XCTAssertEqual(notifications.count, 1)
        XCTAssertEqual(urlResult.status, .succeeded)
        XCTAssertEqual(opened.count, 1)
    }

    func testSubscriptionWritesMemory() async throws {
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let store = LuminaSubscriptionStore()
        let tool = LuminaSubscriptionAddTool(store: store, memoryStore: memory)

        let result = try await tool.call(arguments: ["source": .string("https://example.com/rss")], cancellation: LuminaCancellationToken())
        let search = try await memory.search(LuminaMemorySearchQuery(text: "example", limit: 3))

        XCTAssertEqual(result.status, .succeeded)
        let subscriptionCount = await store.allSubscriptions().count
        XCTAssertEqual(subscriptionCount, 1)
        XCTAssertFalse(search.isEmpty)
    }

    func testSubscriptionStorePersistsSources() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lumina-subscription-\(UUID().uuidString)")
            .appendingPathComponent("subscriptions.json")
        let store = LuminaSubscriptionStore(url: url)
        _ = await store.add(LuminaContentSubscription(source: "https://example.com/feed.xml"))

        let restored = LuminaSubscriptionStore(url: url)
        try await restored.load()
        let subscriptions = await restored.allSubscriptions()

        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.source, "https://example.com/feed.xml")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testReActAgentCalendarReminderFlow() async {
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let ledger = LuminaLedgerStore()
        let subscriptions = LuminaSubscriptionStore()
        let drafts = LuminaMessageDraftCenter()
        let calendar = LuminaVolatileCalendarStore(events: [LuminaCalendarEvent(title: "产品评审会议")])
        let confirmation = LuminaRecordingConfirmationCoordinator(accepted: true)
        let runtime = LuminaAgentRuntime(
            tools: LuminaAppCoreToolFactory.makeTools(
                memoryStore: memory,
                ledgerStore: ledger,
                subscriptionStore: subscriptions,
                messageDrafts: drafts,
                calendarStore: calendar
            ),
            reactPlanner: LuminaFixedReActPlanner(calls: [
                LuminaToolCall(toolName: "calendar.search", arguments: ["query": .string("下一个会议"), "limit": .number(1)]),
                LuminaToolCall(
                    toolName: "reminder.create",
                    arguments: [
                        "title": .string("产品评审会议"),
                        "notes": .string("提前 10 分钟提醒"),
                        "dueDateISO": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(600)))
                    ],
                    requiresConfirmation: true
                )
            ]),
            confirmationCoordinator: confirmation
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "查我下一个会议，并提前 10 分钟提醒我"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "calendar.search" })
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "reminder.create" })
        let reminderCount = await calendar.allReminders().count
        let confirmationCount = await confirmation.requestCount()
        XCTAssertEqual(reminderCount, 1)
        XCTAssertGreaterThan(confirmationCount, 0)
    }

    func testReActAgentCreatesCalendarEventForScheduleIntent() async {
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let ledger = LuminaLedgerStore()
        let subscriptions = LuminaSubscriptionStore()
        let drafts = LuminaMessageDraftCenter()
        let calendar = LuminaVolatileCalendarStore()
        let confirmation = LuminaRecordingConfirmationCoordinator(accepted: true)
        let runtime = LuminaAgentRuntime(
            tools: LuminaAppCoreToolFactory.makeTools(
                memoryStore: memory,
                ledgerStore: ledger,
                subscriptionStore: subscriptions,
                messageDrafts: drafts,
                calendarStore: calendar
            ),
            reactPlanner: LuminaFixedReActPlanner(calls: [
                LuminaToolCall(
                    toolName: "calendar.create",
                    arguments: [
                        "title": .string("出门"),
                        "startDateISO": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(600))),
                        "endDateISO": .string(ISO8601DateFormatter().string(from: Date().addingTimeInterval(2_400))),
                        "notes": .string("我十分钟后要出门，给我定一个日程")
                    ],
                    requiresConfirmation: true
                )
            ]),
            confirmationCoordinator: confirmation
        )

        let result = await runtime.run(request: LuminaAgentRequest(text: "我十分钟后要出门，给我定一个日程"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "calendar.create" })
        let events = await calendar.allEvents()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.title, "出门")
    }
}

final class LuminaAppCorePerformanceTests: XCTestCase {
    func testLocalSearchToolLatency() async throws {
        let memory = LuminaMemoryStore(configuration: LuminaMemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        for document in MemoryDataset.documents(count: 1_000) {
            await memory.ingest(document)
        }
        let tool = LuminaLocalSearchTool(memoryStore: memory)

        let start = ContinuousClock.now
        let result = try await tool.call(arguments: ["query": .string("coffee-3"), "limit": .number(5)], cancellation: LuminaCancellationToken())
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 250 : 1_000)
    }
}

private enum MemoryDataset {
    static func documents(count: Int) -> [LuminaMemoryDocument] {
        (0..<count).map { index in
            LuminaMemoryDocument(
                source: LuminaMemorySource(kind: .appNote, identifier: "app-core-\(index)"),
                title: "Note \(index)",
                body: "AppCore benchmark memory \(index) coffee-\(index % 10)",
                sensitivity: .normal
            )
        }
    }
}

private enum PerformanceBudget {
    static var strict: Bool {
        ProcessInfo.processInfo.environment["LUMINA_STRICT_PERF"] == "1"
    }
}

private enum TestClock {
    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15
    }
}

private actor CapturedURLStore {
    private var urls: [URL] = []

    func record(_ url: URL) {
        urls.append(url)
    }

    func all() -> [URL] {
        urls
    }
}

private actor AskUserProbe {
    private var pendingRequest: LuminaAskUserRequest?
    private var continuation: CheckedContinuation<LuminaAskUserResponse, Never>?

    func waitForAnswer(_ request: LuminaAskUserRequest) async -> LuminaAskUserResponse {
        pendingRequest = request
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func hasPendingRequest() -> Bool {
        pendingRequest != nil && continuation != nil
    }

    func answer(with answers: [LuminaAskUserAnswer]) {
        guard let request = pendingRequest else { return }
        pendingRequest = nil
        continuation?.resume(returning: LuminaAskUserResponse(requestID: request.id, answers: answers))
        continuation = nil
    }
}

private func collectReActCalls(
    _ planner: any LuminaReActPlanner,
    request: LuminaAgentRequest,
    schemas: [LuminaToolSchema],
    maximumToolCalls: Int = 8
) async throws -> [LuminaToolCall] {
    var trace = LuminaReActTrace()
    var calls: [LuminaToolCall] = []

    for iteration in 0..<maximumToolCalls {
        let step = try await planner.nextStep(context: LuminaReActPlannerContext(
            request: request,
            availableTools: schemas,
            trace: trace,
            iteration: iteration,
            remainingToolCalls: maximumToolCalls - calls.count,
            maximumObservationCharacters: 2_000
        ))

        switch step.kind {
        case .action:
            guard let call = step.action else { return calls }
            calls.append(call)
            trace.steps.append(step)
        case .final:
            return calls
        case .thought, .observation:
            trace.steps.append(step)
        }
    }
    return calls
}

private struct LuminaFixedReActPlanner: LuminaReActPlanner {
    let calls: [LuminaToolCall]

    func nextStep(context: LuminaReActPlannerContext) async throws -> LuminaReActStep {
        try Task.checkCancellation()
        let index = context.trace.actionCount
        guard index < calls.count else {
            return .final("## 完成\n\n测试 planner 已完成指定工具调用。")
        }
        return .action(thought: "Test planner selected \(calls[index].toolName).", call: calls[index])
    }
}

private func waitUntil(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    condition: @escaping () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while !(await condition()) {
        if start.duration(to: .now).components.seconds >= Int64(timeoutNanoseconds / 1_000_000_000) {
            throw XCTSkip("Timed out waiting for async condition")
        }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
