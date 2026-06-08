import Foundation
import LuminaAppCore

struct LuminaBenchmarkFixtureIDs: Hashable {
    var calendarEventID: String?
    var reminderID: String?
    var ledgerTransactionID: String?
    var subscriptionID: String?
}

@MainActor
final class LuminaBenchmarkTaskEnvironment {
    let calendarStore = LuminaVolatileCalendarStore()
    let ledgerStore = LuminaLedgerStore(url: nil)
    let subscriptionStore = LuminaSubscriptionStore(url: nil)
    let documentsDirectory: URL
    private(set) var fixtures = LuminaBenchmarkFixtureIDs()

    init(runID: UUID, taskID: String, rootDirectory: URL) {
        self.documentsDirectory = rootDirectory
            .appendingPathComponent("BenchmarkTaskDocuments", isDirectory: true)
            .appendingPathComponent(runID.uuidString, isDirectory: true)
            .appendingPathComponent(taskID, isDirectory: true)
    }

    func prepare(for task: LuminaBenchmarkTask) async throws {
        try prepareFiles(for: task)
        await prepareCalendarAndReminders(for: task)
        await prepareLedger(for: task)
        await prepareSubscriptions(for: task)
    }

    func cleanup(keepArtifacts: Bool) {
        guard !keepArtifacts else { return }
        try? FileManager.default.removeItem(at: documentsDirectory)
    }

    private func prepareCalendarAndReminders(for task: LuminaBenchmarkTask) async {
        let text = task.text
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date().addingTimeInterval(86_400)

        if text.contains("LuminaTest 明天 7 点的日程改成 7 点半") ||
            text.contains("删除那个标题是 LuminaTest 项目同步的日程") {
            let eventStart = calendar.date(bySettingHour: 7, minute: 0, second: 0, of: tomorrow) ?? tomorrow
            let eventEnd = eventStart.addingTimeInterval(1_800)
            let eventID = await calendarStore.addEvent(LuminaCalendarEvent(
                title: "LuminaTest 项目同步",
                startDate: eventStart,
                endDate: eventEnd,
                notes: "Lumina benchmark fixture"
            ))
            fixtures.calendarEventID = eventID
        }

        if text.contains("今天还有哪些提醒") ||
            text.contains("带伞提醒改到明早 8 点半") ||
            text.contains("带伞这个提醒标记完成") ||
            text.contains("删除 LuminaTest 带伞这个提醒") {
            let reminderDue = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow)
            let reminderID = await calendarStore.addReminder(LuminaReminderItem(
                title: "LuminaTest 带伞",
                notes: "Lumina benchmark fixture",
                dueDate: reminderDue
            ))
            fixtures.reminderID = reminderID
        }
    }

    private func prepareLedger(for task: LuminaBenchmarkTask) async {
        let text = task.text
        guard text.contains("查最近的 LuminaTest 咖啡支出") ||
            text.contains("汇总这个月 LuminaTest 咖啡") ||
            text.contains("咖啡账目金额改成 40 元") ||
            text.contains("删除那条 LuminaTest 咖啡账目") else {
            return
        }
        let id = await ledgerStore.append(LuminaLedgerTransaction(
            memo: "LuminaTest 咖啡",
            amount: Decimal(42)
        ))
        fixtures.ledgerTransactionID = id
    }

    private func prepareSubscriptions(for task: LuminaBenchmarkTask) async {
        let text = task.text
        guard text.contains("列出我的订阅源") ||
            text.contains("列出我的 RSS 订阅源") ||
            text.contains("删除 LuminaTest example 这个订阅源") else {
            return
        }
        let id = await subscriptionStore.add(LuminaContentSubscription(
            source: "LuminaTest example https://example.com/feed.xml"
        ))
        fixtures.subscriptionID = id
    }

    private func prepareFiles(for task: LuminaBenchmarkTask) throws {
        let notes = documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        let text = task.text
        if text.contains("列出我保存过的 Lumina 笔记") ||
            text.contains("列出本地 Markdown 笔记") {
            try "# LuminaTest Daily\n\n今天完成 benchmark fixture 验证。\n".write(
                to: notes.appendingPathComponent("LuminaTest-daily.md"),
                atomically: true,
                encoding: .utf8
            )
            try "# LuminaTest\n\n这是一篇用于 benchmark 的本地笔记。\n".write(
                to: notes.appendingPathComponent("LuminaTest.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        if text.contains("LuminaTest-daily.md") {
            try "# LuminaTest Daily\n\n今天完成 benchmark fixture 验证。\n".write(
                to: notes.appendingPathComponent("LuminaTest-daily.md"),
                atomically: true,
                encoding: .utf8
            )
        }
        if text.contains("LuminaTest-report.md") {
            try "# LuminaTest Report\n\nBenchmark covers XML ReAct, tool choice, and local runtime execution.\n".write(
                to: documentsDirectory.appendingPathComponent("LuminaTest-report.md"),
                atomically: true,
                encoding: .utf8
            )
        }
    }
}
