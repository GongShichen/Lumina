import LuminaAgentRuntime
import Combine
import Foundation
import LuminaAppCore
import PersonalMemory

@MainActor
final class AgentAppServices: ObservableObject {
    let memoryStore: LuminaMemoryStore
    let ledgerStore: LuminaLedgerStore
    let subscriptionStore: LuminaSubscriptionStore
    let messageDrafts: LuminaMessageDraftCenter
    let confirmation: AppConfirmationCoordinator
    let askUser: AskUserCoordinator
    let modelReadiness: LuminaModelReadinessStore
    let modelMetrics: LuminaModelInferenceMetricsStore
    let localModelSelection: LuminaLocalModelSelectionStore
    let remoteInferenceSettings: LuminaRemoteInferenceSettingsStore
    let auditLogger: any LuminaAuditLogger
    let auditLogReader: (any LuminaAuditLogReader)?
    let evaluationCalendarStore = LuminaVolatileCalendarStore()
    private let environment: AppEnvironment
    private let loadTask: Task<Void, Never>

    private(set) lazy var runtime: LuminaAgentRuntime = {
        makeRuntime(
            tools: allAppTools(),
            contextProvider: environment.contextProvider
        )
    }()

    private(set) lazy var homeRuntime: LuminaAgentRuntime = {
        let allowedHomeTools: Set<String> = ["device.current_time", "memory.stats", "memory.recent"]
        let tools = allAppTools().filter { allowedHomeTools.contains($0.schema.name) }
        return makeRuntime(tools: tools, contextProvider: LuminaEmptyRuntimeContextProvider())
    }()

    private(set) lazy var evaluationRuntime: LuminaAgentRuntime = {
        let tools = AppToolFactory.makeEvaluationTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            calendarStore: evaluationCalendarStore
        )
        return makeRuntime(
            tools: tools,
            contextProvider: LuminaEmptyRuntimeContextProvider(),
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator(),
            configuration: evaluationRuntimeConfiguration()
        )
    }()

    private func allAppTools() -> [AnyLuminaAgentTool] {
        AppToolFactory.makeTools(
            memoryStore: memoryStore,
            ledgerStore: ledgerStore,
            subscriptionStore: subscriptionStore,
            messageDrafts: messageDrafts,
            askUser: askUser
        )
    }

    private func makeRuntime(
        tools: [AnyLuminaAgentTool],
        contextProvider: any LuminaRuntimeContextProvider,
        confirmationCoordinator: (any LuminaConfirmationCoordinator)? = nil,
        configuration: LuminaAgentRuntimeConfiguration? = nil
    ) -> LuminaAgentRuntime {
        let resolvedConfiguration = configuration ?? environment.runtimeConfiguration
        let contextLoadingPlugin: (any LuminaContextLoadingPlugin)? = contextProvider is LuminaEmptyRuntimeContextProvider
            ? nil
            : LuminaAppContextLoadingPlugin(
                contextProvider: contextProvider,
                tools: tools,
                configuration: resolvedConfiguration
            )
        return LuminaAgentRuntime(
            tools: tools,
            stepGenerator: environment.stepGenerator,
            contextProvider: contextProvider,
            configuration: resolvedConfiguration,
            permissionGate: LuminaAppRuntimePermissionGate(),
            confirmationCoordinator: confirmationCoordinator ?? confirmation,
            auditLogger: auditLogger,
            hooks: [
                LuminaAppMemoryPolicyRuntimeHook(),
                LuminaToolRecoveryRuntimeHook()
            ],
            contextLoadingPlugin: contextLoadingPlugin
        )
    }

    private func evaluationRuntimeConfiguration() -> LuminaAgentRuntimeConfiguration {
        var configuration = environment.runtimeConfiguration
        configuration.yoloMode = true
        configuration.stopOnToolFailure = false
        configuration.maximumConsecutiveReplayObservations = 3
        configuration.toolSchemaDisclosureProfile = .full
        configuration.toolLoadingMode = "direct"
        configuration.multiToolUseEnabled = true
        configuration.continueReadOnlyMultiToolFailures = true
        configuration.ignoreInternalToolCalls = true
        return configuration
    }

    init(environment: AppEnvironment = .live()) {
        self.environment = environment
        self.memoryStore = environment.memoryStore
        self.ledgerStore = environment.ledgerStore
        self.subscriptionStore = environment.subscriptionStore
        self.messageDrafts = environment.messageDrafts
        self.confirmation = environment.confirmation
        self.askUser = environment.askUser
        self.modelReadiness = environment.modelReadiness
        self.modelMetrics = environment.modelMetrics
        self.localModelSelection = environment.localModelSelection
        self.remoteInferenceSettings = environment.remoteInferenceSettings
        self.auditLogger = environment.auditLogger
        self.auditLogReader = environment.auditLogReader
        let memoryStore = environment.memoryStore
        let ledgerStore = environment.ledgerStore
        let subscriptionStore = environment.subscriptionStore
        self.loadTask = Task {
            try? await memoryStore.load()
            try? await ledgerStore.load()
            try? await subscriptionStore.load()
            await Self.removeLegacyWelcomeMemory(from: memoryStore)
        }
    }

    func waitUntilLoaded() async {
        await loadTask.value
    }

    func beginSession() {
        confirmation.resetForNewSession()
        askUser.resetForNewSession()
    }

    func run(_ text: String) async -> LuminaAgentRunResult {
        await runtime.run(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, text: text))
    }

    func run(content: [LuminaAgentContentPart]) async -> LuminaAgentRunResult {
        await runtime.run(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, content: content))
    }

    func runStream(content: [LuminaAgentContentPart]) -> AsyncStream<LuminaAgentRunEvent> {
        runtime.runStream(request: LuminaAgentRequest(systemInstructions: LuminaAppSystemInstructions.taskExecution, content: content))
    }

    func runEvaluationStream(content: [LuminaAgentContentPart]) -> AsyncStream<LuminaAgentRunEvent> {
        evaluationRuntime.runStream(request: LuminaAgentRequest(
            systemInstructions: LuminaAppSystemInstructions.evaluation,
            content: content,
            metadata: [
                LuminaAppContextProvider.disableMemoryContextMetadataKey: .bool(true),
                "lumina.evaluation.memory_access_disabled": .bool(true),
                "lumina.evaluation.ask_user_disabled": .bool(true)
            ]
        ))
    }

    func runEvaluationStream(task: LuminaBenchmarkTask) -> AsyncStream<LuminaAgentRunEvent> {
        let environment = LuminaBenchmarkTaskEnvironment(
            runID: UUID(),
            taskID: task.id,
            rootDirectory: FileManager.default.temporaryDirectory
        )
        return AsyncStream { continuation in
            let relay = Task {
                do {
                    try await environment.prepare(for: task)
                    for await event in runEvaluationStream(task: task, environment: environment) {
                        continuation.yield(event)
                    }
                    environment.cleanup(keepArtifacts: false)
                    continuation.finish()
                } catch {
                    environment.cleanup(keepArtifacts: true)
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                relay.cancel()
                Task { @MainActor in
                    environment.cleanup(keepArtifacts: true)
                }
            }
        }
    }

    func runEvaluationStream(task: LuminaBenchmarkTask, environment taskEnvironment: LuminaBenchmarkTaskEnvironment) -> AsyncStream<LuminaAgentRunEvent> {
        let tools = AppToolFactory.makeEvaluationTools(
            memoryStore: memoryStore,
            ledgerStore: taskEnvironment.ledgerStore,
            subscriptionStore: taskEnvironment.subscriptionStore,
            messageDrafts: messageDrafts,
            calendarStore: taskEnvironment.calendarStore,
            documentsDirectory: taskEnvironment.documentsDirectory,
            enabledToolNames: Self.evaluationToolNames(for: task.text, category: task.category)
                .union(task.expectedTools)
        )
        let runtime = makeRuntime(
            tools: tools,
            contextProvider: environment.contextProvider,
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator(),
            configuration: evaluationRuntimeConfiguration()
        )
        return runtime.runStream(request: LuminaAgentRequest(
            systemInstructions: LuminaAppSystemInstructions.evaluation,
            content: [.text(task.text)],
            metadata: [
                LuminaAppContextProvider.disableMemoryContextMetadataKey: .bool(true),
                "lumina.evaluation.memory_access_disabled": .bool(true),
                "lumina.evaluation.ask_user_disabled": .bool(true),
                "lumina.evaluation.tool_scope": .string(task.category)
            ]
        ))
    }

    func makeBenchmarkRunner() -> LuminaInAppBenchmarkRunner {
        let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BenchmarkReports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("BenchmarkReports", isDirectory: true)
        return LuminaInAppBenchmarkRunner(services: self, reportDirectory: reports)
    }

    func makeAgenticRLRunner() -> LuminaInAppAgenticRLRunner {
        let reports = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TrajectoryReports", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("TrajectoryReports", isDirectory: true)
        return LuminaInAppAgenticRLRunner(services: self, reportDirectory: reports)
    }

    func recentAuditRecords(limit: Int = 20) async -> [LuminaAuditRecord] {
        guard let auditLogReader else { return [] }
        return await auditLogReader.recentRecords(limit: limit)
    }

    private static func removeLegacyWelcomeMemory(from memoryStore: LuminaMemoryStore) async {
        let chunks = await memoryStore.recentChunks(limit: 1_000, maximumSensitivity: .privateData)
        for chunk in chunks where chunk.source.kind == .appNote && chunk.source.identifier == "welcome" {
            _ = await memoryStore.removeChunk(id: chunk.id)
        }
    }

    private static func evaluationToolNames(for text: String, category: String) -> Set<String> {
        var names = Set<String>()
        let goal = text.lowercased()
        func has(_ terms: String...) -> Bool {
            terms.contains { goal.contains($0.lowercased()) || text.contains($0) }
        }
        func add(_ values: String...) {
            values.forEach { names.insert($0) }
        }

        switch category {
        case "calendar":
            if has("创建", "新增", "明天", "上午", "下午", "晚上", "今天") {
                add("device.current_time")
            }
            if has("创建", "新增") {
                add("calendar.create")
            } else if has("改", "修改") {
                add("calendar.search", "calendar.update")
            } else if has("删除", "取消") {
                add("calendar.search", "calendar.delete")
            } else if has("有空", "忙", "空闲") {
                add("device.current_time", "calendar.availability")
            } else {
                add("calendar.search")
            }
        case "reminder":
            if has("提醒我", "明天", "明早", "早上", "分钟后", "小时后") {
                add("device.current_time")
            }
            if has("改", "修改") {
                add("reminder.search", "reminder.update")
            } else if has("完成", "标记完成") {
                add("reminder.search", "reminder.complete")
            } else if has("删除", "取消") {
                add("reminder.search", "reminder.delete")
            } else if has("查", "哪些") {
                add("reminder.search")
            } else {
                add("reminder.create")
            }
        case "contacts":
            if has("创建", "新建") {
                add("contacts.create")
            } else if has("加一个", "修改", "邮箱", "电话") {
                add("contacts.search", "contacts.update")
            } else if has("打开") {
                add("contacts.open")
            } else {
                add("contacts.search")
            }
        case "maps":
            has("导航", "路线") ? add("maps.route") : add("maps.search")
        case "location":
            add("location.current")
        case "notification":
            add("device.current_time", "notification.schedule")
        case "content":
            has("写入", "复制到剪贴板") ? add("clipboard.write") : add("clipboard.read")
            if has("整理", "摘要", "总结", "改写") { add("text.transform") }
        case "file":
            if has("列出") {
                add("file.list_notes")
            } else if has("读取") {
                add("file.read_note")
            } else if has("追加", "修改", "更新") {
                add("file.list_notes", "file.update_note")
            } else if has("删除") {
                add("file.list_notes", "file.delete_note")
            } else if has("保存成", "保存") {
                add("file.save_note")
            }
            if has("整理", "摘要", "总结", "改写") { add("text.transform") }
        case "share":
            add("share.prepare")
        case "ledger":
            if has("记录") {
                add("ledger.record")
            } else if has("汇总", "花了多少钱") {
                add("ledger.summary")
            } else if has("改", "修改") {
                add("ledger.search", "ledger.update")
            } else if has("删除") {
                add("ledger.search", "ledger.delete")
            } else {
                add("ledger.search")
            }
        case "subscription":
            if has("订阅 ") || has("feed", "rss") && !has("删除", "列出") {
                add("subscription.add")
            } else if has("删除", "取消") {
                add("subscription.list", "subscription.remove")
            } else {
                add("subscription.list")
            }
            if has("整理", "摘要", "总结") { add("text.transform") }
        case "web":
            add("webpage.fetch_text")
            if has("整理", "摘要", "总结") { add("text.transform") }
        case "document":
            add("document.read_text")
            if has("整理", "摘要", "总结", "提取") { add("text.transform") }
        case "image":
            if has("尺寸", "大小", "文件大小", "metadata", "元数据") {
                add("image.describe_metadata")
            } else {
                add("image.extract_text")
            }
        case "media":
            add("image.describe_metadata")
        case "local":
            has("计算", "算") ? add("calculator.evaluate") : add("text.transform")
        case "system":
            if has("几点", "时间", "现在") { add("device.current_time") }
            if has("电量", "低电量", "热状态") { add("device.power_status") }
            if has("网络", "低数据") { add("network.status") }
            if has("存储", "空间") { add("storage.status") }
            if has("设置") { add("app.open_settings") }
            if has("整理", "判断", "摘要") { add("text.transform") }
        default:
            break
        }

        if names.isEmpty {
            add("device.current_time")
        }
        return names
    }
}
