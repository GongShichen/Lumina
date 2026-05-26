import Foundation

enum LuminaBenchmarkSuite {
    static func makeTasks(count: Int = 200) -> [LuminaBenchmarkTask] {
        (0..<count).map { index in
            let template = templates[index % templates.count]
            let suffix = index < templates.count ? "" : "（benchmark #\(index + 1)）"
            return LuminaBenchmarkTask(
                id: "task-\(String(format: "%03d", index + 1))",
                text: template.text + suffix,
                expectedTools: template.tools,
                category: template.category,
                sideEffect: template.tools.contains(where: sideEffectTools.contains),
                cleanupPrefixes: template.tools.contains(where: sideEffectTools.contains) ? ["LuminaTest", "test"] : []
            )
        }
    }

    private static let sideEffectTools: Set<String> = [
        "calendar.create", "calendar.update", "calendar.delete",
        "reminder.create", "reminder.update", "reminder.complete", "reminder.delete",
        "contacts.create", "contacts.update", "message.compose", "email.compose", "phone.call",
        "notification.schedule", "clipboard.write", "file.save_note", "file.update_note", "file.delete_note",
        "share.prepare", "app.open_settings",
        "ledger.record", "ledger.update", "ledger.delete", "subscription.add",
        "subscription.remove"
    ]

    private struct Template {
        let text: String
        let tools: [String]
        let category: String
    }

    private static let templates: [Template] = [
        Template(text: "现在几点？", tools: ["device.current_time"], category: "system"),
        Template(text: "帮我查今天下午有没有会议", tools: ["calendar.search"], category: "calendar"),
        Template(text: "帮我创建明天上午 7 点的日程：LuminaTest 去上厕所", tools: ["device.current_time", "calendar.create"], category: "calendar"),
        Template(text: "把 LuminaTest 明天 7 点的日程改成 7 点半", tools: ["calendar.search", "calendar.update"], category: "calendar"),
        Template(text: "删除那个标题是 LuminaTest 项目同步的日程", tools: ["calendar.search", "calendar.delete"], category: "calendar"),
        Template(text: "我明天下午三点到四点有空吗", tools: ["calendar.availability"], category: "calendar"),
        Template(text: "查一下我今天还有哪些提醒", tools: ["reminder.search"], category: "reminder"),
        Template(text: "明天早上 8 点提醒我 LuminaTest 带伞", tools: ["device.current_time", "reminder.create"], category: "reminder"),
        Template(text: "把 LuminaTest 带伞提醒改到明早 8 点半", tools: ["reminder.search", "reminder.update"], category: "reminder"),
        Template(text: "把 LuminaTest 带伞这个提醒标记完成", tools: ["reminder.search", "reminder.complete"], category: "reminder"),
        Template(text: "删除 LuminaTest 带伞这个提醒", tools: ["reminder.search", "reminder.delete"], category: "reminder"),
        Template(text: "找联系人 test 的电话", tools: ["contacts.search"], category: "contacts"),
        Template(text: "创建联系人 LuminaTest test，电话 10086", tools: ["contacts.create"], category: "contacts"),
        Template(text: "给联系人 LuminaTest test 加一个邮箱 test@example.com", tools: ["contacts.search", "contacts.update"], category: "contacts"),
        Template(text: "打开联系人 test 的详情", tools: ["contacts.open"], category: "contacts"),
        Template(text: "帮我给 test 发短信：我十分钟后到", tools: ["message.compose"], category: "communication"),
        Template(text: "给 test 写一封邮件草稿，主题是 LuminaTest 周报", tools: ["email.compose"], category: "communication"),
        Template(text: "给 test 打电话", tools: ["phone.call"], category: "communication"),
        Template(text: "在地图里搜附近咖啡店", tools: ["maps.search"], category: "maps"),
        Template(text: "导航到 Apple Park", tools: ["maps.route"], category: "maps"),
        Template(text: "我现在在哪", tools: ["location.current"], category: "location"),
        Template(text: "半小时后通知我 LuminaTest 喝水", tools: ["device.current_time", "notification.schedule"], category: "notification"),
        Template(text: "读取剪贴板里的链接", tools: ["clipboard.read"], category: "content"),
        Template(text: "把这段文字复制到剪贴板：LuminaTest benchmark", tools: ["clipboard.write"], category: "content"),
        Template(text: "把 LuminaTest 会议纪要保存成 Markdown 笔记", tools: ["file.save_note"], category: "file"),
        Template(text: "列出我保存过的 Lumina 笔记", tools: ["file.list_notes"], category: "file"),
        Template(text: "读取 LuminaTest-daily.md 这篇笔记", tools: ["file.read_note"], category: "file"),
        Template(text: "给 LuminaTest-daily.md 追加今天的进展", tools: ["file.update_note"], category: "file"),
        Template(text: "删除 LuminaTest-daily.md 这篇笔记", tools: ["file.delete_note"], category: "file"),
        Template(text: "分享刚才保存的 LuminaTest 笔记", tools: ["share.prepare"], category: "share"),
        Template(text: "打开 Lumina 的系统设置", tools: ["app.open_settings"], category: "system"),
        Template(text: "查看当前设备电量、网络和可用存储，判断是否适合执行本地任务", tools: ["device.power_status", "network.status", "storage.status"], category: "system"),
        Template(text: "把 LuminaTest benchmark 运行说明保存成 Markdown 笔记", tools: ["file.save_note"], category: "file"),
        Template(text: "把 LuminaTest benchmark 需要覆盖真实工具这段说明保存成 Markdown 笔记", tools: ["file.save_note"], category: "file"),
        Template(text: "把 LuminaTest benchmark 这段文字改写成 3 条检查项", tools: ["text.transform"], category: "local"),
        Template(text: "读取 LuminaTest benchmark 的剪贴板内容并整理摘要", tools: ["clipboard.read", "text.transform"], category: "content"),
        Template(text: "记录 42 元 LuminaTest 咖啡支出", tools: ["ledger.record"], category: "ledger"),
        Template(text: "查最近的 LuminaTest 咖啡支出", tools: ["ledger.search"], category: "ledger"),
        Template(text: "汇总这个月 LuminaTest 咖啡花了多少钱", tools: ["ledger.summary"], category: "ledger"),
        Template(text: "把 LuminaTest 咖啡账目金额改成 40 元", tools: ["ledger.search", "ledger.update"], category: "ledger"),
        Template(text: "删除那条 LuminaTest 咖啡账目", tools: ["ledger.search", "ledger.delete"], category: "ledger"),
        Template(text: "订阅 https://example.com/feed.xml，标题标记 LuminaTest", tools: ["subscription.add"], category: "subscription"),
        Template(text: "列出我的订阅源", tools: ["subscription.list"], category: "subscription"),
        Template(text: "列出我的 RSS 订阅源并整理成一句摘要", tools: ["subscription.list"], category: "subscription"),
        Template(text: "删除 LuminaTest example 这个订阅源", tools: ["subscription.remove"], category: "subscription"),
        Template(text: "抓取 https://example.com 的正文", tools: ["webpage.fetch_text"], category: "web"),
        Template(text: "抓取 https://example.com 的正文并整理成 3 条摘要", tools: ["webpage.fetch_text", "text.transform"], category: "web"),
        Template(text: "读取 Documents 里的 LuminaTest-report.md", tools: ["document.read_text"], category: "document"),
        Template(text: "识别这张图片里的文字", tools: ["image.extract_text"], category: "image"),
        Template(text: "看看这张图片的尺寸和文件大小", tools: ["image.describe_metadata"], category: "image"),
        Template(text: "看看这张 LuminaTest 图片的尺寸、类型和文件大小", tools: ["image.describe_metadata"], category: "media"),
        Template(text: "计算 12*(8+3)-5", tools: ["calculator.evaluate"], category: "local"),
        Template(text: "把这段文字整理成待办列表", tools: ["text.transform"], category: "local"),
        Template(text: "看看当前电量和低电量模式", tools: ["device.power_status"], category: "system"),
        Template(text: "现在网络是不是受限或低数据模式", tools: ["network.status"], category: "system"),
        Template(text: "Lumina 还有多少可用存储空间", tools: ["storage.status"], category: "system"),
        Template(text: "查看当前设备电量、热状态和低电量模式", tools: ["device.power_status"], category: "system"),
        Template(text: "查看当前网络状态和可用存储，并整理成一句摘要", tools: ["network.status", "storage.status", "text.transform"], category: "system"),
        Template(text: "列出本地 Markdown 笔记并整理成一句摘要", tools: ["file.list_notes", "text.transform"], category: "file"),
        Template(text: "查看当前时间、电量和网络状态，判断是否适合继续本地处理", tools: ["device.current_time", "device.power_status", "network.status"], category: "system"),
        Template(text: "把当前时间、电量和网络状态整理成一条 LuminaTest 本地运行记录", tools: ["device.current_time", "device.power_status", "network.status", "text.transform"], category: "system")
    ]
}
