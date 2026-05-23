import XCTest
import AgentRuntime
@testable import LuminaAppCore
@testable import PersonalMemory

final class LuminaAppCoreTests: XCTestCase {
    func testMessageComposeOnlyPublishesDraft() async throws {
        let drafts = MessageDraftCenter()
        let tool = MessageComposeTool(messageDrafts: drafts)

        let result = try await tool.call(arguments: [
            "recipient": .string("Alex"),
            "body": .string("Lunch?")
        ], cancellation: CancellationToken())

        let allDrafts = await drafts.allDrafts()
        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(allDrafts.first?.recipients, ["Alex"])
        XCTAssertEqual(allDrafts.first?.body, "Lunch?")
    }

    func testLedgerRollback() async throws {
        let store = LedgerStore()
        let tool = LedgerRecordTool(store: store)
        let result = try await tool.call(arguments: ["memo": .string("coffee"), "amount": .number(42)], cancellation: CancellationToken())

        let countBeforeRollback = await store.allTransactions().count
        let didRollback = await tool.rollback(result: result)
        let countAfterRollback = await store.allTransactions().count
        XCTAssertEqual(countBeforeRollback, 1)
        XCTAssertTrue(didRollback)
        XCTAssertEqual(countAfterRollback, 0)
    }

    func testSubscriptionWritesMemory() async throws {
        let memory = MemoryStore(configuration: MemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let store = SubscriptionStore()
        let tool = SubscriptionAddTool(store: store, memoryStore: memory)

        let result = try await tool.call(arguments: ["source": .string("https://example.com/rss")], cancellation: CancellationToken())
        let search = try await memory.search(MemorySearchQuery(text: "example", limit: 3))

        XCTAssertEqual(result.status, .succeeded)
        let subscriptionCount = await store.allSubscriptions().count
        XCTAssertEqual(subscriptionCount, 1)
        XCTAssertFalse(search.isEmpty)
    }

    func testReActAgentCalendarReminderFlow() async {
        let memory = MemoryStore(configuration: MemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        let ledger = LedgerStore()
        let subscriptions = SubscriptionStore()
        let drafts = MessageDraftCenter()
        let calendar = InMemoryCalendarStore(events: [CalendarEvent(title: "产品评审会议")])
        let confirmation = RecordingConfirmationCoordinator(accepted: true)
        let runtime = AgentRuntime(
            tools: AppCoreToolFactory.makeTools(
                memoryStore: memory,
                ledgerStore: ledger,
                subscriptionStore: subscriptions,
                messageDrafts: drafts,
                calendarStore: calendar
            ),
            planner: RuleBasedPlanner(),
            confirmationCoordinator: confirmation
        )

        let result = await runtime.run(request: AgentRequest(text: "查我下一个会议，并提前 10 分钟提醒我"))

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "calendar.search" })
        XCTAssertTrue(result.plan.toolCalls.contains { $0.toolName == "reminder.create" })
        let reminderCount = await calendar.allReminders().count
        let confirmationCount = await confirmation.requestCount()
        XCTAssertEqual(reminderCount, 1)
        XCTAssertGreaterThan(confirmationCount, 0)
    }
}

final class LuminaAppCorePerformanceTests: XCTestCase {
    func testLocalSearchToolLatency() async throws {
        let memory = MemoryStore(configuration: MemoryStoreConfiguration(scheduleBackgroundEmbedding: false, persistAfterIngest: false))
        for document in MemoryDataset.documents(count: 1_000) {
            await memory.ingest(document)
        }
        let tool = LocalSearchTool(memoryStore: memory)

        let start = ContinuousClock.now
        let result = try await tool.call(arguments: ["query": .string("coffee-3"), "limit": .number(5)], cancellation: CancellationToken())
        let elapsed = TestClock.milliseconds(since: start)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertLessThan(elapsed, PerformanceBudget.strict ? 250 : 1_000)
    }
}

private enum MemoryDataset {
    static func documents(count: Int) -> [MemoryDocument] {
        (0..<count).map { index in
            MemoryDocument(
                source: MemorySource(kind: .appNote, identifier: "app-core-\(index)"),
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
