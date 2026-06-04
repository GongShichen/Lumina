import LuminaAgentRuntime
@preconcurrency import EventKit
import Foundation
import LuminaAppCore
import PersonalMemory

#if canImport(UIKit)
import UIKit
#endif

#if os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
import AppKit
#endif

enum AppToolFactory {
    static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        askUser: AskUserCoordinator
    ) -> [AnyLuminaAgentTool] {
        makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            askUser: askUser.ask
        )
    }

    static func makeEvaluationTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        calendarStore: LuminaVolatileCalendarStore,
        enabledToolNames: Set<String>? = nil
    ) -> [AnyLuminaAgentTool] {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let localTools: [AnyLuminaAgentTool] = [
            LuminaCurrentTimeTool().eraseToAnyTool(),
            LuminaAppCore.LuminaCalendarSearchTool(store: calendarStore).eraseToAnyTool(),
            LuminaAppCore.LuminaCalendarCreateTool(store: calendarStore).eraseToAnyTool(),
            LuminaAppCore.LuminaReminderCreateTool(store: calendarStore).eraseToAnyTool(),
            LuminaAppCore.LuminaContactsSearchTool(searchContacts: Self.evaluationContactsSearch).eraseToAnyTool(),
            LuminaClipboardReadTool().eraseToAnyTool(),
            LuminaFileSaveNoteTool(documentsDirectory: documentsDirectory).eraseToAnyTool(),
            LuminaLedgerRecordTool(store: ledgerStore).eraseToAnyTool(),
            LuminaLedgerSearchTool(store: ledgerStore).eraseToAnyTool(),
            LuminaSubscriptionAddTool(store: subscriptionStore, memoryStore: memoryStore).eraseToAnyTool()
        ]
        let extendedTools = LuminaExtendedToolCatalog.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            calendarStore: calendarStore,
            documentsDirectory: documentsDirectory,
            openURL: { _ in true },
            contactsCreate: Self.evaluationContactCreate,
            contactsUpdate: Self.evaluationContactUpdate,
            contactsOpen: Self.evaluationContactOpen,
            sharePrepare: Self.evaluationSharePrepare,
            clipboardWrite: Self.evaluationClipboardWrite,
            includePIMTools: true
        )
        let syntheticTools = [
            Self.evaluationClipboardReadTool(),
            Self.evaluationLocationTool(),
            Self.evaluationNotificationTool(),
            Self.evaluationWebpageFetchTextTool(),
            Self.evaluationDocumentReadTextTool(),
            Self.evaluationImageExtractTextTool(),
            Self.evaluationImageDescribeMetadataTool()
        ]
        let blockedExternalTools: Set<String> = ["email.compose", "message.compose", "phone.call"]
        let tools = replacingTools(
            localTools + platformFilteredTools(extendedTools).filter { !blockedExternalTools.contains($0.schema.name) },
            with: syntheticTools
        )
        guard let enabledToolNames else {
            return tools
        }
        return tools.filter { enabledToolNames.contains($0.schema.name) }
    }

    static func makeTools(
        memoryStore: LuminaMemoryStore,
        ledgerStore: LuminaLedgerStore,
        subscriptionStore: LuminaSubscriptionStore,
        messageDrafts: LuminaMessageDraftCenter,
        askUser: @escaping LuminaAskUserTool.AskUser
    ) -> [AnyLuminaAgentTool] {
        let documentsDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ??
            FileManager.default.temporaryDirectory
        let baseTools: [AnyLuminaAgentTool] = [
            LuminaCurrentTimeTool().eraseToAnyTool(),
            LuminaAskUserTool(askUser: askUser).eraseToAnyTool(),
            LuminaMediaImportTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaLocalSearchTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaCalendarSearchTool().eraseToAnyTool(),
            LuminaCalendarCreateTool().eraseToAnyTool(),
            LuminaReminderCreateTool().eraseToAnyTool(),
            LuminaContactsSearchTool().eraseToAnyTool(),
            LuminaLocationCurrentTool().eraseToAnyTool(),
            LuminaNotificationScheduleTool().eraseToAnyTool(),
            LuminaClipboardReadTool().eraseToAnyTool(),
            LuminaFileSaveNoteTool(documentsDirectory: documentsDirectory).eraseToAnyTool(),
            LuminaURLOpenTool().eraseToAnyTool(),
            LuminaMemoryIngestTextTool(memoryStore: memoryStore).eraseToAnyTool(),
            LuminaMessageComposeTool(messageDrafts: messageDrafts).eraseToAnyTool(),
            LuminaLedgerRecordTool(store: ledgerStore).eraseToAnyTool(),
            LuminaLedgerSearchTool(store: ledgerStore).eraseToAnyTool(),
            LuminaSubscriptionAddTool(store: subscriptionStore, memoryStore: memoryStore).eraseToAnyTool()
        ]
        let platformWeatherHealth = Self.weatherHealthExecutors()
        let extendedTools = LuminaExtendedToolCatalog.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            calendarStore: LuminaVolatileCalendarStore(),
            documentsDirectory: documentsDirectory,
            openURL: Self.openURL,
            currentWeather: platformWeatherHealth.currentWeather,
            forecastWeather: platformWeatherHealth.forecastWeather,
            healthSummary: platformWeatherHealth.healthSummary,
            healthSamples: platformWeatherHealth.healthSamples,
            contactsCreate: LuminaContactMutationExecutor.createContact,
            contactsUpdate: LuminaContactMutationExecutor.updateContact,
            contactsOpen: LuminaContactMutationExecutor.openContact,
            sharePrepare: LuminaShareExecutor.prepareShare,
            clipboardWrite: LuminaClipboardWriteExecutor.writeClipboard,
            includePIMTools: false
        )
        return baseTools + LuminaEventKitManagementToolFactory.makeTools() + Self.platformFilteredTools(extendedTools)
    }

    private static func weatherHealthExecutors() -> (
        currentWeather: LuminaExtendedToolCatalog.CurrentWeather?,
        forecastWeather: LuminaExtendedToolCatalog.ForecastWeather?,
        healthSummary: LuminaExtendedToolCatalog.HealthSummary?,
        healthSamples: LuminaExtendedToolCatalog.HealthSamples?
    ) {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return (
            LuminaWeatherHealthExecutor.currentWeather,
            LuminaWeatherHealthExecutor.forecastWeather,
            LuminaWeatherHealthExecutor.healthSummary,
            LuminaWeatherHealthExecutor.healthSamples
        )
        #else
        return (nil, nil, nil, nil)
        #endif
    }

    private static func platformFilteredTools(_ tools: [AnyLuminaAgentTool]) -> [AnyLuminaAgentTool] {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return tools
        #else
        return tools.filter { tool in
            !tool.schema.name.hasPrefix("weather.") && !tool.schema.name.hasPrefix("health.")
        }
        #endif
    }

    private static func evaluationContactsSearch(query: String, limit: Int) async throws -> [LuminaContactSearchResult] {
        let contacts = [
            LuminaContactSearchResult(identifier: "contact-luminatest-test", name: "LuminaTest test", phones: ["10086"], emails: ["test@example.com"]),
            LuminaContactSearchResult(identifier: "contact-test", name: "test", phones: ["10086"], emails: ["test@example.com"])
        ]
        let lowered = query.lowercased()
        return Array(contacts.filter { contact in
            lowered.isEmpty ||
                contact.name.lowercased().contains(lowered) ||
                contact.phones.contains(where: { $0.lowercased().contains(lowered) }) ||
                contact.emails.contains(where: { $0.lowercased().contains(lowered) })
        }.prefix(max(1, limit)))
    }

    private static func evaluationContactCreate(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let name = arguments.string("name") ?? "LuminaTest test"
        return LuminaToolResult(
            callID: UUID(),
            toolName: "contacts.create",
            status: .succeeded,
            output: ["id": .string("contact-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))"), "name": .string(name)],
            content: [.text("联系人已创建：[id=contact-luminatest-test] \(name)")]
        )
    }

    private static func evaluationContactUpdate(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let id = arguments.string("id") ?? "contact-luminatest-test"
        return LuminaToolResult(
            callID: UUID(),
            toolName: "contacts.update",
            status: .succeeded,
            output: ["id": .string(id)],
            content: [.text("联系人已更新：[id=\(id)]")]
        )
    }

    private static func evaluationContactOpen(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let query = arguments.string("query") ?? arguments.string("name") ?? "test"
        return LuminaToolResult(
            callID: UUID(),
            toolName: "contacts.open",
            status: .succeeded,
            output: ["query": .string(query)],
            content: [.text("联系人详情已准备打开：\(query)")]
        )
    }

    private static func evaluationSharePrepare(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        LuminaToolResult(
            callID: UUID(),
            toolName: "share.prepare",
            status: .succeeded,
            output: arguments,
            content: [.text("分享内容已准备。")]
        )
    }

    private static func evaluationClipboardWrite(arguments: [String: LuminaJSONValue]) async throws -> LuminaToolResult {
        let text = arguments.string("text") ?? ""
        return LuminaToolResult(
            callID: UUID(),
            toolName: "clipboard.write",
            status: .succeeded,
            output: ["textLength": .number(Double(text.count))],
            content: [.text("已写入剪贴板：\(text.count) 个字符。")]
        )
    }

    private static func replacingTools(_ tools: [AnyLuminaAgentTool], with overrides: [AnyLuminaAgentTool]) -> [AnyLuminaAgentTool] {
        let overrideNames = Set(overrides.map(\.schema.name))
        var seen = Set<String>()
        var result: [AnyLuminaAgentTool] = []
        for tool in tools where !overrideNames.contains(tool.schema.name) {
            guard seen.insert(tool.schema.name).inserted else { continue }
            result.append(tool)
        }
        for tool in overrides {
            guard seen.insert(tool.schema.name).inserted else { continue }
            result.append(tool)
        }
        return result
    }

    private static func evaluationClipboardReadTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "clipboard.read",
                description: "读取剪贴板文本。",
                parameters: [],
                sideEffect: .readOnly,
                sensitivity: .sensitive
            )
        ) { _, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "clipboard.read",
                status: .succeeded,
                output: ["text": .string("LuminaTest benchmark clipboard content"), "characterCount": .number(37)],
                content: [.text("剪贴板内容：LuminaTest benchmark clipboard content")]
            )
        }
    }

    private static func evaluationLocationTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "location.current",
                description: "读取当前位置。",
                parameters: [],
                sideEffect: .readOnly,
                sensitivity: .privateData
            )
        ) { _, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "location.current",
                status: .succeeded,
                output: ["latitude": .number(37.3349), "longitude": .number(-122.0090), "label": .string("Apple Park")],
                content: [.text("当前位置约为 Apple Park 附近。")]
            )
        }
    }

    private static func evaluationNotificationTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "notification.schedule",
                description: "安排本地通知。",
                parameters: [
                    LuminaToolParameterSchema(name: "title", type: .string, description: "通知标题。", required: false),
                    LuminaToolParameterSchema(name: "body", type: .string, description: "通知正文。", required: false),
                    LuminaToolParameterSchema(name: "dateISO", type: .dateISO8601, description: "通知时间。", required: false)
                ],
                sideEffect: .systemWrite,
                sensitivity: .privateData,
                idempotencyPolicy: "caller_keyed"
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "notification.schedule",
                status: .succeeded,
                output: arguments,
                content: [.text("本地通知已安排。")]
            )
        }
    }

    private static func evaluationWebpageFetchTextTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "webpage.fetch_text",
                description: "抓取公开 URL 并提取文本摘要。",
                parameters: [LuminaToolParameterSchema(name: "url", type: .string, description: "公开 URL。")],
                sideEffect: .readOnly,
                sensitivity: .sensitive
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            let url = arguments.string("url") ?? "https://example.com"
            return LuminaToolResult(
                callID: UUID(),
                toolName: "webpage.fetch_text",
                status: .succeeded,
                output: [
                    "url": .string(url),
                    "title": .string("Example Domain"),
                    "text": .string("Example Domain is a stable benchmark page used for LuminaTest web reading.")
                ],
                content: [.text("已读取网页：Example Domain")]
            )
        }
    }

    private static func evaluationDocumentReadTextTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "document.read_text",
                description: "读取 App sandbox 内 txt、md 或 pdf 文本。",
                parameters: [LuminaToolParameterSchema(name: "path", type: .string, description: "文件路径或文件名。")],
                sideEffect: .readOnly,
                sensitivity: .sensitive
            )
        ) { arguments, cancellation in
            try cancellation.checkCancellation()
            let requested = arguments.string("path") ?? arguments.string("filename") ?? "LuminaTest-report.md"
            let text = requested.localizedCaseInsensitiveContains("report")
                ? "LuminaTest report: benchmark covers real tool selection, XML ReAct formatting, and local runtime execution."
                : "LuminaTest daily note: today completed isolated benchmark fixture validation."
            return LuminaToolResult(
                callID: UUID(),
                toolName: "document.read_text",
                status: .succeeded,
                output: ["filename": .string(URL(fileURLWithPath: requested).lastPathComponent), "text": .string(text)],
                content: [.text("已读取文档 \(URL(fileURLWithPath: requested).lastPathComponent)。")]
            )
        }
    }

    private static func evaluationImageExtractTextTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "image.extract_text",
                description: "使用 OCR 提取图片文字。",
                parameters: [LuminaToolParameterSchema(name: "path", type: .string, description: "图片路径。", required: false)],
                sideEffect: .readOnly,
                sensitivity: .privateData
            )
        ) { _, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "image.extract_text",
                status: .succeeded,
                output: ["text": .string("LuminaTest image text")],
                content: [.text("已识别图片文字：LuminaTest image text")]
            )
        }
    }

    private static func evaluationImageDescribeMetadataTool() -> AnyLuminaAgentTool {
        AnyLuminaAgentTool(
            schema: LuminaToolSchema(
                name: "image.describe_metadata",
                description: "读取图片尺寸、类型和文件大小。",
                parameters: [LuminaToolParameterSchema(name: "path", type: .string, description: "图片路径。", required: false)],
                sideEffect: .readOnly,
                sensitivity: .sensitive
            )
        ) { _, cancellation in
            try cancellation.checkCancellation()
            return LuminaToolResult(
                callID: UUID(),
                toolName: "image.describe_metadata",
                status: .succeeded,
                output: ["filename": .string("LuminaTest-image.png"), "width": .number(640), "height": .number(360), "byteCount": .number(12345)],
                content: [.text("图片 LuminaTest-image.png：640 x 360，12345 bytes。")]
            )
        }
    }

    @MainActor
    private static func openURL(_ url: URL) async -> Bool {
        #if targetEnvironment(macCatalyst)
        if url.scheme?.localizedCaseInsensitiveCompare("mailto") == .orderedSame {
            return false
        }
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url) { success in
                continuation.resume(returning: success)
            }
        }
        #elseif canImport(UIKit)
        return await withCheckedContinuation { continuation in
            UIApplication.shared.open(url) { success in
                continuation.resume(returning: success)
            }
        }
        #elseif os(macOS) && !targetEnvironment(macCatalyst) && canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }
}
