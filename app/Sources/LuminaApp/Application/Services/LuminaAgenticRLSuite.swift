import Foundation

enum LuminaAgenticRLSuite {
    static func makeTasks(count: Int = 200) -> [LuminaAgenticRLTask] {
        let availableTemplates = templates.filter { template in
            !template.tools.contains(where: isUnavailableForCurrentPlatform)
        }
        return (0..<count).map { index in
            let template = availableTemplates[index % availableTemplates.count]
            let round = index / availableTemplates.count
            let suffix = round == 0 ? "" : "（RL batch \(round + 1)，编号 \(index + 1)）"
            return LuminaAgenticRLTask(
                id: "rl-\(String(format: "%03d", index + 1))",
                instruction: template.instruction + suffix,
                category: template.category,
                expectedTools: template.tools,
                difficulty: template.difficulty,
                cleanupPrefixes: ["LuminaTest", "test"]
            )
        }
    }

    private static func isUnavailableForCurrentPlatform(_ toolName: String) -> Bool {
        #if targetEnvironment(macCatalyst)
        return toolName == "message.compose" || toolName == "email.compose" || toolName == "phone.call"
        #else
        return false
        #endif
    }

    private struct Template {
        let instruction: String
        let category: String
        let difficulty: String
        let tools: [String]
    }

    private static let templates: [Template] = [
        Template(instruction: "请先读取本机时间，再查看明天上午 7:00 到 7:30 的日历忙闲。如果没有冲突，就创建一个标题为 LuminaTest 早起准备 的日程；如果有冲突，不要追问，直接在最终回答说明冲突并停止创建。", category: "calendar_conflict_resolution", difficulty: "hard", tools: ["device.current_time", "calendar.availability", "calendar.create"]),
        Template(instruction: "帮我规划明天下午的 LuminaTest 深度工作：先查日历冲突，再把可行时间段保存成一篇 Markdown 笔记，不要读取或写入本地记忆。", category: "schedule_file", difficulty: "hard", tools: ["device.current_time", "calendar.availability", "file.save_note"]),
        Template(instruction: "查找联系人 test；如果能找到电话号码，就准备一条短信草稿，内容是我会晚 10 分钟到；如果没有唯一可用号码，不要追问，最终回答说明无法准备短信草稿的原因。", category: "communication_resolution", difficulty: "medium", tools: ["contacts.search", "message.compose"]),
        Template(instruction: "读取剪贴板中的文本，提取其中可能的待办事项，把结果整理成 Markdown 笔记 LuminaTest-clipboard-todos.md，不要写入本地记忆。", category: "content_file", difficulty: "medium", tools: ["clipboard.read", "text.transform", "file.save_note"]),
        Template(instruction: "帮我创建一个 LuminaTest 晚间复盘流程：今晚 21:30 创建提醒，提醒内容包括回顾支出、整理待办、查看明早日程。", category: "reminder_schedule", difficulty: "medium", tools: ["device.current_time", "calendar.search", "reminder.create"]),
        Template(instruction: "查询最近的 LuminaTest 咖啡支出，并汇总本月咖啡花费；如果没有记录，就创建一条 18 元 LuminaTest 咖啡支出作为测试账目。", category: "ledger", difficulty: "medium", tools: ["ledger.search", "ledger.summary", "ledger.record"]),
        Template(instruction: "订阅 https://example.com/feed.xml，标题使用 LuminaTest Example Feed；然后列出订阅源确认它存在，不要刷新或写入本地记忆。", category: "subscription", difficulty: "hard", tools: ["subscription.add", "subscription.list"]),
        Template(instruction: "请查看当前电量、低电量模式、网络状态和可用存储，然后给出是否适合执行长时间本地索引任务的判断。", category: "system_diagnostics", difficulty: "medium", tools: ["device.power_status", "network.status", "storage.status"]),
        Template(instruction: "根据当前位置搜索附近咖啡店，并结合当前电量判断是否适合继续在外处理任务；不要自动导航。", category: "location_system", difficulty: "medium", tools: ["location.current", "device.power_status", "maps.search"]),
        Template(instruction: "查询今天的日历和未完成提醒，结合当前设备状态，给出一个不超过 5 条的 LuminaTest 今日行动建议；不要创建或修改系统数据。", category: "calendar_reminder_system", difficulty: "hard", tools: ["calendar.search", "reminder.search", "device.power_status"]),
        Template(instruction: "把 https://example.com 的正文抓取下来，提炼 3 个要点，保存为 LuminaTest-example-summary.md，不要写入本地记忆。", category: "web_file", difficulty: "hard", tools: ["webpage.fetch_text", "text.transform", "file.save_note"]),
        Template(instruction: "读取 Documents 中的 LuminaTest-report.md，提取行动项；如果文件不可用，请给出明确失败原因，不要编造内容。", category: "document", difficulty: "medium", tools: ["document.read_text", "text.transform"]),
        Template(instruction: "请识别附件图片中的文字，再把文字整理成会议纪要格式；如果没有图片附件，不要追问，直接最终回答说明需要用户重新提交带图片的任务。", category: "image_ocr_guardrail", difficulty: "hard", tools: ["image.extract_text", "text.transform"]),
        Template(instruction: "创建联系人 LuminaTest test，电话 10086，邮箱 test@example.com；创建后再打开该联系人详情。", category: "contacts", difficulty: "medium", tools: ["contacts.create", "contacts.open"]),
        Template(instruction: "查找联系人 test 的邮箱，准备一封主题为 LuminaTest 周报 的邮件草稿，正文包含 3 条项目进展占位。", category: "email", difficulty: "medium", tools: ["contacts.search", "email.compose"]),
        Template(instruction: "创建一个明天早上 8 点的 LuminaTest 出门提醒，并同时创建一个 7:50 的本地通知；最终回复里区分系统提醒事项和本地通知。", category: "reminder_notification", difficulty: "hard", tools: ["device.current_time", "reminder.create", "notification.schedule"]),
        Template(instruction: "把一段 LuminaTest 训练记录保存成 Markdown 文件；最终只说明保存状态，不读取或写入本地记忆。", category: "file_write", difficulty: "hard", tools: ["file.save_note"]),
        Template(instruction: "基于当前时间、电量和网络状态生成一段 LuminaTest 运行记录，保存为 Markdown 文件，不写入本地记忆。", category: "context_file", difficulty: "hard", tools: ["device.current_time", "device.power_status", "network.status", "file.save_note"]),
        Template(instruction: "列出本地 Markdown 笔记，找到 LuminaTest-daily.md 后追加一段今天的总结；如果不存在，就先创建它。", category: "file_update", difficulty: "hard", tools: ["file.list_notes", "file.update_note", "file.save_note"]),
        Template(instruction: "请打开 Apple Maps 搜索 Apple Park，并准备一条发给 test 的短信草稿，说明我正在查看路线但不会自动拨号或发送。", category: "maps_communication", difficulty: "medium", tools: ["maps.search", "message.compose"]),
        Template(instruction: "读取剪贴板 URL，如果是网页就抓取正文并总结；如果不是 URL，就把剪贴板文本改写成更清晰的三条 bullet。", category: "conditional_content", difficulty: "hard", tools: ["clipboard.read", "webpage.fetch_text", "text.transform"]),
        Template(instruction: "计算 42*7+18，然后把结果复制到剪贴板，并保存一条 LuminaTest 计算记录到 Markdown 文件。", category: "calculator_file", difficulty: "medium", tools: ["calculator.evaluate", "clipboard.write", "file.save_note"]),
        Template(instruction: "帮我检查今天是否有名为 LuminaTest 项目同步 的日程；如果有，把它改到下午 4 点；如果没有，创建一个 30 分钟日程。", category: "calendar_upsert", difficulty: "hard", tools: ["calendar.search", "calendar.update", "calendar.create"]),
        Template(instruction: "查找未完成的 LuminaTest 待办，完成其中标题含 带伞 的事项；如果没有，创建一个明早 8 点带伞提醒。", category: "reminder_upsert", difficulty: "hard", tools: ["reminder.search", "reminder.complete", "reminder.create"]),
        Template(instruction: "查询本月 LuminaTest 支出摘要，然后把摘要保存为 LuminaTest-ledger-summary.md，并准备系统分享面板。", category: "ledger_share", difficulty: "hard", tools: ["ledger.summary", "file.save_note", "share.prepare"]),
        Template(instruction: "查看明天上午日历和未完成提醒，若 8 点前没有出门准备事项，就创建 LuminaTest 出门准备提醒；否则只在最终回复中说明不创建提醒。", category: "reminder_conditional", difficulty: "hard", tools: ["calendar.search", "reminder.search", "reminder.create"]),
        Template(instruction: "查看当前位置和存储状态，生成一份 LuminaTest 设备上下文摘要并保存为 Markdown 文件。", category: "device_file", difficulty: "medium", tools: ["location.current", "storage.status", "file.save_note"]),
        Template(instruction: "基于当前时间、明天上午日历忙闲和未完成提醒，生成一个保守的 LuminaTest 工作计划 Markdown 文件；不要追问用户，也不要创建日历事件。", category: "contextual_work_plan_file", difficulty: "hard", tools: ["device.current_time", "calendar.availability", "reminder.search", "file.save_note"]),
        Template(instruction: "列出订阅源，并把列表摘要保存成 LuminaTest subscription list Markdown 文件；如果没有订阅源，说明为空列表。", category: "subscription_file", difficulty: "hard", tools: ["subscription.list", "file.save_note"]),
        Template(instruction: "把 LuminaTest 临时计划写成 Markdown 文件，然后准备系统分享面板；不要读取或删除任何本地记忆。", category: "file_share", difficulty: "medium", tools: ["file.save_note", "share.prepare"]),
        Template(instruction: "删除 LuminaTest-daily.md 文件，然后列出剩余笔记确认它已经消失；如果删除失败，输出可恢复建议。", category: "file_delete", difficulty: "medium", tools: ["file.delete_note", "file.list_notes"]),
        Template(instruction: "创建一个 LuminaTest 快速出门流程：先读取时间，再安排 10 分钟后的日程，最后安排 9 分钟后的本地通知。", category: "multi_side_effect", difficulty: "hard", tools: ["device.current_time", "calendar.create", "notification.schedule"]),
        Template(instruction: "查找联系人 test，如果有唯一可用电话号码，就准备电话入口；如果没有唯一号码，不要追问，最终回答说明没有执行呼叫入口。", category: "phone_guardrail", difficulty: "hard", tools: ["contacts.search", "phone.call"]),
        Template(instruction: "打开 Lumina 设置页前，先说明为什么需要设置；然后通过工具打开设置，不要在最终回复里给虚假的系统状态。", category: "settings", difficulty: "medium", tools: ["app.open_settings"]),
        Template(instruction: "读取图片元数据并判断是否适合 OCR；如果尺寸信息可用，再决定是否调用 OCR。", category: "image_policy", difficulty: "medium", tools: ["image.describe_metadata", "image.extract_text"]),
        Template(instruction: "将剪贴板内容、当前时间和当前电量整理成一条 LuminaTest 上下文记录，保存为 Markdown 文件。", category: "context_note", difficulty: "hard", tools: ["clipboard.read", "device.current_time", "device.power_status", "file.save_note"]),
        Template(instruction: "查询最近账目，判断我是否已经记录过 LuminaTest 咖啡；如果没有，就新增一条 22 元记录，并把判断过程保存成笔记。", category: "cross_store_reasoning", difficulty: "hard", tools: ["ledger.search", "ledger.record", "file.save_note"]),
        Template(instruction: "检查网络状态，如果可联网就抓取 https://example.com 并保存摘要；如果不可联网，只输出失败原因。", category: "network_web", difficulty: "hard", tools: ["network.status", "webpage.fetch_text", "file.save_note"]),
        Template(instruction: "请根据今天的日历和提醒事项，生成一段不超过 120 字的行动摘要，不要创建或修改任何系统数据。", category: "read_only_summary", difficulty: "medium", tools: ["calendar.search", "reminder.search"]),
        Template(instruction: "删除 LuminaTest example 订阅源，然后列出订阅源确认；如果不存在，最终回复要说明没有删除。", category: "subscription_delete", difficulty: "medium", tools: ["subscription.remove", "subscription.list"])
    ]
}
