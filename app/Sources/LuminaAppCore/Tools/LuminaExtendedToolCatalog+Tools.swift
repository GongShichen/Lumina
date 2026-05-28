import LuminaAgentRuntime
import Foundation
import PersonalMemory

#if canImport(PDFKit)
import PDFKit
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(Vision)
import Vision
#endif

extension LuminaExtendedToolCatalog {
    static func pimTools(calendarStore: LuminaVolatileCalendarStore) -> [LuminaConfiguredTool] {
        [
            tool(name: "calendar.update", description: "修改日历事件标题、时间或备注。", params: [
                param("id", "事件 identifier。"),
                param("title", "新标题。", required: false),
                param("startDateISO", "新的开始时间。", type: .dateISO8601, required: false),
                param("endDateISO", "新的结束时间。", type: .dateISO8601, required: false),
                param("notes", "备注。", required: false, sensitive: true)
            ], sideEffect: .systemWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("calendar.update", "缺少事件 identifier。") }
                let event = await calendarStore.updateEvent(
                    id: id,
                    title: arguments.string("title"),
                    startDate: date(arguments.string("startDateISO")),
                    endDate: date(arguments.string("endDateISO")),
                    notes: arguments.string("notes")
                )
                guard let event else { return failed("calendar.update", "没有找到要修改的日历事件。") }
                return succeeded("calendar.update", "日程已更新：\(event.title)", [
                    "id": .string(event.id.uuidString),
                    "title": .string(event.title),
                    "startDateISO": .string(iso(event.startDate))
                ])
            },
            tool(name: "calendar.delete", description: "删除指定日历事件。", params: [param("id", "事件 identifier。")], sideEffect: .systemWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("calendar.delete", "缺少事件 identifier。") }
                let removed = await calendarStore.removeEvent(id: id)
                return removed ? succeeded("calendar.delete", "日历事件已删除。", ["id": .string(id)]) : failed("calendar.delete", "没有找到要删除的日历事件。")
            },
            tool(name: "calendar.availability", description: "查询指定时间段内的忙闲状态。", params: [
                param("startDateISO", "开始时间。", type: .dateISO8601),
                param("endDateISO", "结束时间。", type: .dateISO8601)
            ], sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let start = date(arguments.string("startDateISO")) ?? Date()
                let end = date(arguments.string("endDateISO")) ?? start.addingTimeInterval(3_600)
                let events = await calendarStore.allEvents().filter { event in
                    let eventEnd = event.endDate ?? event.startDate.addingTimeInterval(1_800)
                    return event.startDate < end && eventEnd > start
                }
                let summary = events.isEmpty ? "这段时间没有已知日程冲突。" : "这段时间有 \(events.count) 个日程冲突。"
                return succeeded("calendar.availability", summary, [
                    "busy": .bool(!events.isEmpty),
                    "events": .array(events.map { .string($0.title) })
                ])
            },
            tool(name: "reminder.search", description: "查询提醒事项。", params: [
                param("query", "提醒关键词。", required: false),
                param("limit", "最多返回数量。", type: .number, required: false)
            ], sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let query = arguments.string("query")?.lowercased() ?? ""
                let limit = max(1, min(20, Int(arguments.number("limit") ?? 10)))
                let reminders = await calendarStore.allReminders()
                    .filter { query.isEmpty || $0.title.lowercased().contains(query) }
                    .prefix(limit)
                let values = reminders.map { reminder in
                    LuminaJSONValue.object([
                        "id": .string(reminder.id.uuidString),
                        "title": .string(reminder.title),
                        "isCompleted": .bool(reminder.isCompleted),
                        "dueDateISO": reminder.dueDate.map { .string(iso($0)) } ?? .null
                    ])
                }
                return succeeded("reminder.search", values.isEmpty ? "没有找到提醒事项。" : "找到 \(values.count) 条提醒事项。", ["reminders": .array(Array(values))])
            },
            tool(name: "reminder.update", description: "修改提醒事项。", params: [
                param("id", "提醒 identifier。"),
                param("title", "新标题。", required: false),
                param("notes", "备注。", required: false, sensitive: true),
                param("dueDateISO", "截止时间。", type: .dateISO8601, required: false),
                param("isCompleted", "是否完成。", type: .bool, required: false)
            ], sideEffect: .systemWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("reminder.update", "缺少提醒 identifier。") }
                let reminder = await calendarStore.updateReminder(
                    id: id,
                    title: arguments.string("title"),
                    notes: arguments.string("notes"),
                    dueDate: date(arguments.string("dueDateISO")),
                    isCompleted: arguments.bool("isCompleted")
                )
                guard let reminder else { return failed("reminder.update", "没有找到要修改的提醒。") }
                return succeeded("reminder.update", "提醒已更新：\(reminder.title)", ["id": .string(reminder.id.uuidString), "title": .string(reminder.title)])
            },
            tool(name: "reminder.complete", description: "标记提醒事项完成。", params: [param("id", "提醒 identifier。")], sideEffect: .systemWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("reminder.complete", "缺少提醒 identifier。") }
                let reminder = await calendarStore.updateReminder(id: id, title: nil, notes: nil, dueDate: nil, isCompleted: true)
                guard let reminder else { return failed("reminder.complete", "没有找到要完成的提醒。") }
                return succeeded("reminder.complete", "提醒已完成：\(reminder.title)", ["id": .string(id)])
            },
            tool(name: "reminder.delete", description: "删除提醒事项。", params: [param("id", "提醒 identifier。")], sideEffect: .systemWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("reminder.delete", "缺少提醒 identifier。") }
                let removed = await calendarStore.removeReminder(id: id)
                return removed ? succeeded("reminder.delete", "提醒已删除。", ["id": .string(id)]) : failed("reminder.delete", "没有找到要删除的提醒。")
            }
        ]
    }

    static func communicationTools(
        openURL: @escaping OpenURL,
        contactsCreate: ContactsMutation?,
        contactsUpdate: ContactsMutation?,
        contactsOpen: ContactsMutation?,
        sharePrepare: SharePrepare?,
        clipboardWrite: ClipboardWrite?
    ) -> [LuminaConfiguredTool] {
        [
            delegatedTool("contacts.create", "创建联系人。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
                param("name", "姓名。", sensitive: true),
                param("phone", "电话。", required: false, sensitive: true),
                param("email", "邮箱。", required: false, sensitive: true)
            ], delegate: contactsCreate),
            delegatedTool("contacts.update", "更新联系人电话、邮箱或公司。", sideEffect: .systemWrite, sensitivity: .privateData, params: [
                param("id", "联系人 identifier。", required: false, sensitive: true),
                param("name", "姓名或关键词。", required: false, sensitive: true),
                param("phone", "电话。", required: false, sensitive: true),
                param("email", "邮箱。", required: false, sensitive: true),
                param("organization", "公司。", required: false, sensitive: true)
            ], delegate: contactsUpdate),
            delegatedTool("contacts.open", "打开联系人详情或系统通讯录搜索。", sideEffect: .externalCommunication, sensitivity: .privateData, params: [
                param("query", "联系人姓名或关键词。", sensitive: true)
            ], delegate: contactsOpen),
            tool(name: "email.compose", description: "打开邮件草稿，不能静默发送。", params: [
                param("to", "收件人邮箱。", required: false, sensitive: true),
                param("recipient", "收件人邮箱或联系人别名。", required: false, sensitive: true),
                param("subject", "主题。", required: false, sensitive: true),
                param("body", "正文。", required: false, sensitive: true)
            ], sideEffect: .externalCommunication, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let hasDraftContent = ["to", "recipient", "subject", "body"].contains { key in
                    !(arguments.string(key)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                }
                guard hasDraftContent else {
                    return failed("email.compose", "邮件草稿缺少收件人、主题或正文，未打开外部邮件 App。")
                }
                let url = mailtoURL(arguments)
                let opened = await openURL(url)
                return opened ? succeeded("email.compose", "邮件草稿已打开。", ["url": .string(url.absoluteString)]) : failed("email.compose", "系统没有接受邮件草稿打开请求。")
            },
            tool(name: "phone.call", description: "打开电话或 FaceTime 呼叫入口，不能静默拨号。", params: [
                param("number", "电话号码或 FaceTime 地址。", sensitive: true),
                param("kind", "phone 或 facetime。", required: false)
            ], sideEffect: .externalCommunication, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let target = arguments.string("number") ?? ""
                let scheme = arguments.string("kind")?.lowercased() == "facetime" ? "facetime" : "tel"
                guard let url = URL(string: "\(scheme)://\(target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else {
                    return failed("phone.call", "号码或地址格式不可用。")
                }
                let opened = await openURL(url)
                return opened ? succeeded("phone.call", "已打开呼叫入口。", ["url": .string(url.absoluteString)]) : failed("phone.call", "当前平台无法打开呼叫入口。")
            },
            tool(name: "maps.search", description: "打开 Apple Maps 搜索地点。", params: [param("query", "地点或关键词。")], sideEffect: .externalCommunication, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                let query = arguments.string("query") ?? ""
                let escaped = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let url = URL(string: "http://maps.apple.com/?q=\(escaped)")!
                let opened = await openURL(url)
                return opened ? succeeded("maps.search", "已打开地图搜索。", ["query": .string(query)]) : failed("maps.search", "当前平台无法打开地图。")
            },
            tool(name: "maps.route", description: "打开 Apple Maps 路线。", params: [
                param("destination", "目的地。"),
                param("source", "起点。", required: false),
                param("mode", "d=驾车、w=步行、r=公交。", required: false)
            ], sideEffect: .externalCommunication, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                let destination = (arguments.string("destination") ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let source = (arguments.string("source") ?? "").addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let mode = arguments.string("mode") ?? "d"
                let sourcePart = source.isEmpty ? "" : "&saddr=\(source)"
                let url = URL(string: "http://maps.apple.com/?daddr=\(destination)\(sourcePart)&dirflg=\(mode)")!
                let opened = await openURL(url)
                return opened ? succeeded("maps.route", "已打开地图路线。", ["url": .string(url.absoluteString)]) : failed("maps.route", "当前平台无法打开路线。")
            },
            delegatedTool("clipboard.write", "写入剪贴板。", sideEffect: .appLocalWrite, sensitivity: .sensitive, params: [param("text", "要写入的文本。", sensitive: true)], delegate: clipboardWrite),
            delegatedTool("share.prepare", "准备分享文本或文件并打开系统分享面板。", sideEffect: .externalCommunication, sensitivity: .sensitive, params: [
                param("text", "分享文本。", required: false, sensitive: true),
                param("filePath", "App sandbox 文件路径。", required: false, sensitive: true)
            ], delegate: sharePrepare),
            tool(name: "app.open_settings", description: "打开 Lumina 系统设置页。", params: [], sideEffect: .externalCommunication, sensitivity: .normal) { _, cancellation in
                try cancellation.checkCancellation()
                let opened = await openURL(URL(string: "x-apple.systempreferences:")!)
                return opened ? succeeded("app.open_settings", "已打开设置入口。", [:]) : failed("app.open_settings", "当前平台无法打开设置入口。")
            }
        ]
    }

    static func memoryLedgerSubscriptionTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore
    ) -> [LuminaConfiguredTool] {
        [
            tool(name: "memory.recent", description: "读取最近本地记忆摘要。", params: [param("limit", "最多返回数量。", type: .number, required: false)], sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let limit = max(1, min(20, Int(arguments.number("limit") ?? 5)))
                let chunks = await memoryStore.recentChunks(limit: limit)
                let values = chunks.map { chunk in
                    LuminaJSONValue.object(["id": .string(chunk.id.uuidString), "title": .string(chunk.title), "summary": .string(chunk.summary)])
                }
                return succeeded("memory.recent", chunks.isEmpty ? "暂无本地记忆。" : "读取到 \(chunks.count) 条最近记忆。", ["memories": .array(values)])
            },
            tool(name: "memory.stats", description: "读取本地记忆索引统计。", params: [], sensitivity: .privateData) { _, cancellation in
                try cancellation.checkCancellation()
                let stats = await memoryStore.stats()
                return succeeded("memory.stats", "本地记忆共有 \(stats.chunkCount) 个片段。", [
                    "chunkCount": .number(Double(stats.chunkCount)),
                    "embeddedChunkCount": .number(Double(stats.embeddedChunkCount))
                ])
            },
            tool(name: "memory.delete", description: "删除指定记忆片段或清空记忆库。", params: [
                param("id", "记忆片段 id。", required: false),
                param("all", "是否删除全部。", type: .bool, required: false)
            ], sideEffect: .appLocalWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                if arguments.bool("all") == true {
                    let count = await memoryStore.removeAll()
                    return succeeded("memory.delete", "已删除 \(count) 条记忆片段。", ["deletedCount": .number(Double(count))])
                }
                guard let rawID = arguments.string("id"), let id = UUID(uuidString: rawID) else {
                    return failed("memory.delete", "缺少有效的记忆片段 id。")
                }
                let removed = await memoryStore.removeChunk(id: id)
                return removed ? succeeded("memory.delete", "记忆片段已删除。", ["id": .string(rawID)]) : failed("memory.delete", "没有找到要删除的记忆片段。")
            },
            tool(name: "ledger.summary", description: "汇总真实账目记录。", params: [param("query", "关键词。", required: false)], sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                let query = arguments.string("query")?.lowercased() ?? ""
                let txs = await ledgerStore.allTransactions().filter { query.isEmpty || $0.memo.lowercased().contains(query) }
                let total = txs.compactMap(\.amount).reduce(Decimal.zero, +)
                return succeeded("ledger.summary", "找到 \(txs.count) 条账目，总额 \(NSDecimalNumber(decimal: total).doubleValue)。", [
                    "count": .number(Double(txs.count)),
                    "total": .number(NSDecimalNumber(decimal: total).doubleValue)
                ])
            },
            tool(name: "ledger.update", description: "修改账目备注或金额。", params: [
                param("id", "账目 id。"),
                param("memo", "新备注。", required: false, sensitive: true),
                param("amount", "新金额。", type: .number, required: false)
            ], sideEffect: .appLocalWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("ledger.update", "缺少账目 id。") }
                let amount = arguments.number("amount").map { Decimal($0) }
                guard let updated = await ledgerStore.update(id: id, memo: arguments.string("memo"), amount: amount) else {
                    return failed("ledger.update", "没有找到要修改的账目。")
                }
                return succeeded("ledger.update", "账目已更新：\(updated.memo)", ["id": .string(id)])
            },
            tool(name: "ledger.delete", description: "删除账目记录。", params: [param("id", "账目 id。")], sideEffect: .appLocalWrite, sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("ledger.delete", "缺少账目 id。") }
                let removed = await ledgerStore.remove(id: id)
                return removed ? succeeded("ledger.delete", "账目已删除。", ["id": .string(id)]) : failed("ledger.delete", "没有找到要删除的账目。")
            },
            tool(name: "subscription.list", description: "列出真实订阅源。", params: [], sensitivity: .normal) { _, cancellation in
                try cancellation.checkCancellation()
                let subscriptions = await subscriptionStore.allSubscriptions()
                let values = subscriptions.map { LuminaJSONValue.object(["id": .string($0.id.uuidString), "source": .string($0.source)]) }
                return succeeded("subscription.list", subscriptions.isEmpty ? "暂无订阅源。" : "共有 \(subscriptions.count) 个订阅源。", ["subscriptions": .array(values)])
            },
            tool(name: "subscription.refresh", description: "刷新 RSS/Atom 订阅并把摘要写入本地记忆。", params: [param("id", "订阅 id。", required: false)], sideEffect: .appLocalWrite, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                let subscriptions = await subscriptionStore.allSubscriptions()
                let selected = arguments.string("id").flatMap { id in subscriptions.first { $0.id.uuidString == id } } ?? subscriptions.first
                guard let selected, let url = URL(string: selected.source) else {
                    return failed("subscription.refresh", "没有可刷新的订阅源。")
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(data: data, encoding: .utf8) ?? ""
                let title = firstMatch("<title>(.*?)</title>", in: text) ?? selected.source
                _ = await memoryStore.ingest(LuminaMemoryDocument(
                    source: LuminaMemorySource(kind: .subscription, identifier: selected.source),
                    title: "订阅更新：\(title)",
                    body: text.strippingMarkup().truncated(to: 2_000),
                    sensitivity: .normal
                ))
                return succeeded("subscription.refresh", "订阅已刷新并写入本地记忆：\(title)", ["source": .string(selected.source), "title": .string(title)])
            },
            tool(name: "subscription.remove", description: "删除订阅源。", params: [param("id", "订阅 id。")], sideEffect: .appLocalWrite, sensitivity: .normal) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let id = arguments.string("id") else { return failed("subscription.remove", "缺少订阅 id。") }
                let removed = await subscriptionStore.remove(id: id)
                return removed ? succeeded("subscription.remove", "订阅源已删除。", ["id": .string(id)]) : failed("subscription.remove", "没有找到要删除的订阅源。")
            }
        ]
    }

    static func contentTools(memoryStore: LuminaMemoryStore, documentsDirectory: URL) -> [LuminaConfiguredTool] {
        [
            tool(name: "file.list_notes", description: "列出 Lumina Documents 内的 Markdown 笔记。", params: [], sensitivity: .sensitive) { _, cancellation in
                try cancellation.checkCancellation()
                let files = noteFiles(in: documentsDirectory)
                let values = files.map { LuminaJSONValue.object(["filename": .string($0.lastPathComponent), "path": .string($0.path)]) }
                return succeeded("file.list_notes", files.isEmpty ? "暂无 Lumina 笔记。" : "找到 \(files.count) 个笔记。", ["files": .array(values)])
            },
            tool(name: "file.read_note", description: "读取 Lumina Markdown 笔记。", params: [param("filename", "文件名。", sensitive: true)], sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let url = noteURL(arguments, documentsDirectory: documentsDirectory), FileManager.default.fileExists(atPath: url.path) else {
                    return failed("file.read_note", "没有找到指定笔记。")
                }
                let text = try String(contentsOf: url, encoding: .utf8)
                return succeeded("file.read_note", "已读取笔记 \(url.lastPathComponent)。", ["filename": .string(url.lastPathComponent), "body": .string(text)])
            },
            tool(name: "file.update_note", description: "追加或覆盖 Lumina 笔记。", params: [
                param("filename", "文件名。", sensitive: true),
                param("body", "正文。", sensitive: true),
                param("mode", "append 或 overwrite。", required: false)
            ], sideEffect: .appLocalWrite, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let url = noteURL(arguments, documentsDirectory: documentsDirectory) else {
                    return failed("file.update_note", "缺少文件名。")
                }
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                let body = arguments.string("body") ?? ""
                if arguments.string("mode")?.lowercased() == "append", FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: Data("\n\(body)\n".utf8))
                    try handle.close()
                } else {
                    try body.data(using: .utf8)?.write(to: url, options: .atomic)
                }
                return succeeded("file.update_note", "笔记已更新：\(url.lastPathComponent)", ["filename": .string(url.lastPathComponent)])
            },
            tool(name: "file.delete_note", description: "删除 Lumina 笔记。", params: [param("filename", "文件名。", sensitive: true)], sideEffect: .appLocalWrite, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let url = noteURL(arguments, documentsDirectory: documentsDirectory), FileManager.default.fileExists(atPath: url.path) else {
                    return failed("file.delete_note", "没有找到指定笔记。")
                }
                try FileManager.default.removeItem(at: url)
                return succeeded("file.delete_note", "笔记已删除：\(url.lastPathComponent)", ["filename": .string(url.lastPathComponent)])
            },
            tool(name: "webpage.fetch_text", description: "抓取公开 URL 并提取文本摘要。", params: [param("url", "公开 URL。", sensitive: true)], sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let raw = arguments.string("url"), let url = URL(string: raw) else {
                    return failed("webpage.fetch_text", "URL 格式不可用。")
                }
                let (data, response) = try await URLSession.shared.data(from: url)
                let text = String(data: data, encoding: .utf8) ?? ""
                let title = firstMatch("<title>(.*?)</title>", in: text) ?? url.host() ?? raw
                let body = text.strippingMarkup().truncated(to: 4_000)
                return succeeded("webpage.fetch_text", "已读取网页：\(title)", [
                    "url": .string((response.url ?? url).absoluteString),
                    "title": .string(title),
                    "text": .string(body)
                ])
            },
            tool(name: "webpage.save_to_memory", description: "把公开网页摘要保存到本地记忆。", params: [param("url", "公开 URL。", sensitive: true)], sideEffect: .appLocalWrite, sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let raw = arguments.string("url"), let url = URL(string: raw) else {
                    return failed("webpage.save_to_memory", "URL 格式不可用。")
                }
                let (data, _) = try await URLSession.shared.data(from: url)
                let text = String(data: data, encoding: .utf8) ?? ""
                let title = firstMatch("<title>(.*?)</title>", in: text) ?? raw
                _ = await memoryStore.ingest(LuminaMemoryDocument(
                    source: LuminaMemorySource(kind: .imported, identifier: raw),
                    title: title,
                    body: text.strippingMarkup().truncated(to: 4_000),
                    sensitivity: .normal
                ))
                return succeeded("webpage.save_to_memory", "网页摘要已保存到本地记忆：\(title)", ["url": .string(url.absoluteString), "title": .string(title)])
            },
            tool(name: "document.read_text", description: "读取 App sandbox 内 txt、md 或 pdf 文本。", params: [param("path", "App sandbox 文件路径。", sensitive: true)], sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let path = arguments.string("path") else { return failed("document.read_text", "缺少文件路径。") }
                let url = URL(fileURLWithPath: path)
                let ext = url.pathExtension.lowercased()
                let text: String
                if ext == "txt" || ext == "md" {
                    text = try String(contentsOf: url, encoding: .utf8)
                } else if ext == "pdf" {
                    #if canImport(PDFKit)
                    text = PDFDocument(url: url)?.string ?? ""
                    #else
                    return failed("document.read_text", "当前平台没有 PDFKit，无法读取 PDF 文本。")
                    #endif
                } else {
                    return failed("document.read_text", "只支持 txt、md 和 pdf 文件。")
                }
                return succeeded("document.read_text", "已读取文档 \(url.lastPathComponent)。", ["text": .string(text.truncated(to: 8_000)), "filename": .string(url.lastPathComponent)])
            },
            tool(name: "image.describe_metadata", description: "读取图片尺寸、类型和文件大小。", params: [param("path", "App sandbox 图片路径。", sensitive: true)], sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let path = arguments.string("path") else { return failed("image.describe_metadata", "缺少图片路径。") }
                let url = URL(fileURLWithPath: path)
                let size = ((try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.doubleValue) ?? 0
                #if canImport(ImageIO)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
                    return failed("image.describe_metadata", "无法读取图片元数据。")
                }
                let width = properties[kCGImagePropertyPixelWidth] as? Double ?? 0
                let height = properties[kCGImagePropertyPixelHeight] as? Double ?? 0
                return succeeded("image.describe_metadata", "图片 \(url.lastPathComponent)：\(Int(width)) x \(Int(height))，\(Int(size)) bytes。", [
                    "filename": .string(url.lastPathComponent),
                    "width": .number(width),
                    "height": .number(height),
                    "byteCount": .number(size)
                ])
                #else
                return succeeded("image.describe_metadata", "图片 \(url.lastPathComponent)：\(Int(size)) bytes。", ["filename": .string(url.lastPathComponent), "byteCount": .number(size)])
                #endif
            },
            tool(name: "image.extract_text", description: "使用 Vision OCR 提取图片文字。", params: [param("path", "App sandbox 图片路径。", sensitive: true)], sensitivity: .privateData) { arguments, cancellation in
                try cancellation.checkCancellation()
                guard let path = arguments.string("path") else { return failed("image.extract_text", "缺少图片路径。") }
                #if canImport(Vision) && canImport(ImageIO)
                let url = URL(fileURLWithPath: path)
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    return failed("image.extract_text", "无法读取图片。")
                }
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                try VNImageRequestHandler(cgImage: image).perform([request])
                let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
                return succeeded("image.extract_text", text.isEmpty ? "没有识别到文字。" : "已识别 \(text.count) 个字符。", ["text": .string(text)])
                #else
                return failed("image.extract_text", "当前平台没有可用的 Vision OCR。")
                #endif
            },
            tool(name: "calculator.evaluate", description: "本地计算四则表达式。", params: [param("expression", "表达式。")], sensitivity: .low) { arguments, cancellation in
                try cancellation.checkCancellation()
                let expression = arguments.string("expression") ?? ""
                var parser = ArithmeticParser(expression)
                let result = try parser.parse()
                return succeeded("calculator.evaluate", "\(expression) = \(result)", ["result": .number(result)])
            },
            tool(name: "text.transform", description: "本地文本整理、分点或提取待办。", params: [
                param("text", "输入文本。", sensitive: true),
                param("mode", "bullets、todos 或 cleanup。", required: false)
            ], sensitivity: .sensitive) { arguments, cancellation in
                try cancellation.checkCancellation()
                let text = arguments.string("text") ?? ""
                let mode = arguments.string("mode") ?? "cleanup"
                let transformed = transform(text, mode: mode)
                return succeeded("text.transform", "文本已整理。", ["text": .string(transformed)])
            }
        ]
    }

    static func systemTools(documentsDirectory: URL) -> [LuminaConfiguredTool] {
        [
            tool(name: "device.power_status", description: "读取低电量模式、thermal state 和可用电量字段。", params: [], sensitivity: .normal) { _, cancellation in
                try cancellation.checkCancellation()
                let process = ProcessInfo.processInfo
                return succeeded("device.power_status", "低电量模式：\(process.isLowPowerModeEnabled ? "开启" : "关闭")。", [
                    "lowPowerMode": .bool(process.isLowPowerModeEnabled),
                    "thermalState": .string(String(describing: process.thermalState)),
                    "unavailableFields": .array([.string("batteryLevel may require UIKit UIDevice on iOS")])
                ])
            },
            tool(name: "network.status", description: "读取当前网络路径状态。", params: [], sensitivity: .normal) { _, cancellation in
                try cancellation.checkCancellation()
                return succeeded("network.status", "网络状态会在 App 平台实现中提供；当前 AppCore 默认未注入实时网络监听。", [
                    "status": .string("unknown"),
                    "unavailableFields": .array([.string("real-time NWPathMonitor not injected")])
                ])
            },
            tool(name: "storage.status", description: "读取 App 可用存储和 Lumina Notes 占用。", params: [], sensitivity: .normal) { _, cancellation in
                try cancellation.checkCancellation()
                let values = try documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                let notesSize = folderSize(documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true))
                let available = Double(values.volumeAvailableCapacityForImportantUsage ?? 0)
                return succeeded("storage.status", "可用空间约 \(Int(available / 1_048_576)) MiB，笔记占用 \(notesSize) bytes。", [
                    "availableBytes": .number(available),
                    "notesBytes": .number(Double(notesSize))
                ])
            }
        ]
    }

    static func weatherAndHealthTools(
        currentWeather: CurrentWeather?,
        forecastWeather: ForecastWeather?,
        healthSummary: HealthSummary?,
        healthSamples: HealthSamples?
    ) -> [LuminaConfiguredTool] {
        [
            delegatedTool("weather.current", "读取当前位置或指定经纬度的当前天气。", sensitivity: .sensitive, params: [
                param("latitude", "纬度。", type: .number, required: false),
                param("longitude", "经度。", type: .number, required: false)
            ], delegate: currentWeather),
            delegatedTool("weather.forecast", "读取小时或每日天气预报摘要。", sensitivity: .sensitive, params: [
                param("latitude", "纬度。", type: .number, required: false),
                param("longitude", "经度。", type: .number, required: false),
                param("days", "天数。", type: .number, required: false)
            ], delegate: forecastWeather),
            delegatedTool("health.summary", "读取 HealthKit 健康摘要。", sensitivity: .privateData, params: [
                param("startDateISO", "开始时间。", type: .dateISO8601, required: false),
                param("endDateISO", "结束时间。", type: .dateISO8601, required: false),
                param("metrics", "指标数组。", type: .array, required: false)
            ], delegate: healthSummary),
            delegatedTool("health.query_samples", "读取指定 HealthKit 指标的少量样本摘要。", sensitivity: .privateData, params: [
                param("metric", "指标名。"),
                param("startDateISO", "开始时间。", type: .dateISO8601, required: false),
                param("endDateISO", "结束时间。", type: .dateISO8601, required: false),
                param("limit", "最多返回数量。", type: .number, required: false)
            ], delegate: healthSamples)
        ]
    }
}

private func tool(
    name: String,
    description: String,
    params: [LuminaToolParameterSchema],
    sideEffect: LuminaToolSideEffect = .readOnly,
    sensitivity: LuminaToolSensitivity,
    handler: @escaping LuminaConfiguredTool.Handler
) -> LuminaConfiguredTool {
    LuminaConfiguredTool(
        schema: LuminaToolSchema(
            name: name,
            description: description,
            parameters: params,
            sideEffect: sideEffect,
            sensitivity: sensitivity,
            acceptedInputModalities: [.text, .structuredData],
            outputModalities: [.text, .structuredData],
            requiresUserInteraction: sideEffect == .externalCommunication,
            idempotencyPolicy: luminaIdempotencyPolicy(for: name, sideEffect: sideEffect),
            destructive: name.contains(".delete") || name.contains(".remove"),
            concurrencySafe: sideEffect == .readOnly,
            maxResultSize: 1_500
        ),
        handler: handler
    )
}

private func luminaIdempotencyPolicy(for name: String, sideEffect: LuminaToolSideEffect) -> String {
    guard sideEffect != .readOnly else { return "replay_identical" }
    if name.contains(".create") ||
        name.contains(".compose") ||
        name.contains(".schedule") ||
        name.contains(".open") ||
        name.contains(".prepare") ||
        name.contains(".record") ||
        name.contains(".add") ||
        name.contains(".save") ||
        name.contains(".write") ||
        name == "webpage.save_to_memory" ||
        name == "memory.ingest_text" {
        return "caller_keyed"
    }
    return "replay_identical"
}

private func delegatedTool(
    _ name: String,
    _ description: String,
    sideEffect: LuminaToolSideEffect = .readOnly,
    sensitivity: LuminaToolSensitivity,
    params: [LuminaToolParameterSchema],
    delegate: (@Sendable ([String: LuminaJSONValue]) async throws -> LuminaToolResult)?
) -> LuminaConfiguredTool {
    tool(name: name, description: description, params: params, sideEffect: sideEffect, sensitivity: sensitivity) { arguments, cancellation in
        try cancellation.checkCancellation()
        guard let delegate else {
            return failed(name, "当前平台没有启用 \(name) 的真实执行器。")
        }
        return try await delegate(arguments)
    }
}

private func param(
    _ name: String,
    _ description: String,
    type: LuminaToolParameterType = .string,
    required: Bool = true,
    sensitive: Bool = false
) -> LuminaToolParameterSchema {
    LuminaToolParameterSchema(name: name, type: type, description: description, required: required, sensitive: sensitive)
}

private func succeeded(_ toolName: String, _ message: String, _ output: [String: LuminaJSONValue]) -> LuminaToolResult {
    LuminaToolResult(callID: UUID(), toolName: toolName, status: .succeeded, output: output.merging(["summary": .string(message)]) { current, _ in current }, content: [.markdown(message)])
}

private func failed(_ toolName: String, _ message: String) -> LuminaToolResult {
    LuminaToolResult(callID: UUID(), toolName: toolName, status: .failed, output: ["summary": .string(message)], content: [.markdown(message)], errorMessage: message)
}

private func date(_ value: String?) -> Date? {
    guard let value else { return nil }
    return ISO8601DateFormatter().date(from: value)
}

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

private func noteFiles(in documentsDirectory: URL) -> [URL] {
    let directory = documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true)
    return ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension.lowercased() == "md" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

private func noteURL(_ arguments: [String: LuminaJSONValue], documentsDirectory: URL) -> URL? {
    guard let filename = arguments.string("filename") else { return nil }
    let sanitized = filename.replacingOccurrences(of: "/", with: "-")
    return documentsDirectory.appendingPathComponent("Lumina Notes", isDirectory: true).appendingPathComponent(sanitized.hasSuffix(".md") ? sanitized : "\(sanitized).md")
}

private func folderSize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
    return enumerator.compactMap { item -> Int64? in
        guard let url = item as? URL,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }.reduce(0, +)
}

private func firstMatch(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          match.numberOfRanges > 1,
          let range = Range(match.range(at: 1), in: text) else {
        return nil
    }
    return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func mailtoURL(_ arguments: [String: LuminaJSONValue]) -> URL {
    var components = URLComponents()
    components.scheme = "mailto"
    components.path = arguments.string("to") ?? arguments.string("recipient") ?? ""
    components.queryItems = [
        arguments.string("subject").map { URLQueryItem(name: "subject", value: $0) },
        arguments.string("body").map { URLQueryItem(name: "body", value: $0) }
    ].compactMap { $0 }
    return components.url ?? URL(string: "mailto:")!
}

private func transform(_ text: String, mode: String) -> String {
    let lines = text.split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    switch mode.lowercased() {
    case "bullets":
        return lines.map { "- \($0)" }.joined(separator: "\n")
    case "todos":
        return lines.filter { $0.contains("要") || $0.contains("需要") || $0.lowercased().contains("todo") }.map { "- [ ] \($0)" }.joined(separator: "\n")
    default:
        return lines.joined(separator: "\n")
    }
}
