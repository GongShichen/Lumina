import LuminaAgentRuntime
import Combine
import Foundation
import LuminaAppCore
import PhotosUI
import PersonalMemory
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AgentHomeViewModel: ObservableObject {
    @Published var selectedTab: LuminaTab = .agent
    @Published var prompt = ""
    @Published var homeContent = HomeContent.loading()
    @Published var isRunning = false
    @Published var resultText = ""
    @Published var resultContent: [LuminaAgentContentPart] = []
    @Published var timelineItems: [AgentRunTimelineItem] = []
    @Published var auditRecords: [LuminaAuditRecord] = []
    @Published var stats = LuminaMemoryIndexStats(documentCount: 0, chunkCount: 0, embeddedChunkCount: 0, cacheEntryCount: 0)
    @Published var pendingMessage: LuminaMessageDraft?
    @Published var pendingConfirmation: ConfirmationRequest?
    @Published var pendingAskUser: LuminaAskUserRequest?
    @Published var askUserStatus: AskUserStatus?
    @Published var modelReadiness = LuminaModelReadinessSnapshot.initial
    @Published var activitySnapshot = LuminaAgentActivitySnapshot.idle
    @Published var runSummary: LuminaAgentRunSummary?
    @Published var attachments: [MultimodalAttachment] = []
    @Published var pendingVoiceAttachment: MultimodalAttachment?
    @Published var voiceTranscriptDraft = ""
    @Published var photoSelection: [PhotosPickerItem] = []
    @Published var isFileImporterPresented = false
    @Published private(set) var voiceState: VoiceInputState = .idle
    @Published private(set) var voiceTranscript = ""
    @Published private(set) var benchmarkSnapshot = LuminaBenchmarkSnapshot()
    @Published private(set) var agenticRLSnapshot = LuminaAgenticRLSnapshot()

    let memoryViewModel = PersonalMemoryViewModel()
    private let voiceInput: VoiceInputController
    private let activityCenter = LuminaAgentActivityCenter()
    private var services: AgentAppServices?
    private var runTask: Task<Void, Never>?
    private var benchmarkTask: Task<Void, Never>?
    private var agenticRLTask: Task<Void, Never>?
    private var benchmarkRunID: UUID?
    private var agenticRLRunID: UUID?
    private var messageDraftTask: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []
    private var didStart = false
    private var scenePhase: ScenePhase = .active

    init(services: AgentAppServices? = nil, voiceInput: VoiceInputController = VoiceInputController()) {
        self.services = services
        self.voiceInput = voiceInput
        bindVoiceInput()
    }

    func start() {
        guard let services else { return }
        guard !didStart else { return }
        didStart = true
        bindConfirmation(services: services)
        bindAskUser(services: services)
        bindModelReadiness(services: services)
        memoryViewModel.configure(memoryStore: services.memoryStore, stats: stats, onMemoryChanged: { [weak self] in
            await self?.refreshStats()
        })
        startMessageDraftStream(services: services)
        Task { await refreshInitialData() }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        benchmarkTask?.cancel()
        benchmarkTask = nil
        agenticRLTask?.cancel()
        agenticRLTask = nil
        benchmarkRunID = nil
        agenticRLRunID = nil
        messageDraftTask?.cancel()
        messageDraftTask = nil
    }

    func runAction() {
        isRunning ? cancelRun() : runAgent()
    }

    func updateScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
    }

    func resolveConfirmation(id: UUID, accepted: Bool) {
        services?.confirmation.resolve(id: id, accepted: accepted)
    }

    func submitAskUser(requestID: UUID, answers: [LuminaAskUserAnswer]) {
        services?.askUser.submit(requestID: requestID, answers: answers)
    }

    func cancelAskUser(requestID: UUID) {
        services?.askUser.cancel(requestID: requestID)
    }

    func runBenchmark() {
        guard let services else { return }
        benchmarkTask?.cancel()
        agenticRLTask?.cancel()
        let runID = UUID()
        benchmarkRunID = runID
        agenticRLRunID = nil
        agenticRLSnapshot = LuminaAgenticRLSnapshot()
        benchmarkSnapshot = LuminaBenchmarkSnapshot(state: .running, currentTask: "准备 200 条真实任务", completed: 0, total: 200)
        benchmarkTask = Task { [weak self] in
            guard let self else { return }
            await services.waitUntilLoaded()
            guard self.benchmarkRunID == runID, !Task.isCancelled else { return }
            let runner = services.makeBenchmarkRunner()
            _ = await runner.run(taskCount: 200) { snapshot in
                guard self.benchmarkRunID == runID else { return }
                self.benchmarkSnapshot = snapshot
            }
            guard self.benchmarkRunID == runID, !Task.isCancelled else { return }
            self.benchmarkTask = nil
            await self.refreshStats()
            await self.refreshAuditRecords()
        }
    }

    func cancelBenchmark() {
        benchmarkRunID = nil
        benchmarkTask?.cancel()
        benchmarkTask = nil
        benchmarkSnapshot = LuminaBenchmarkSnapshot(state: .cancelled, currentTask: "Benchmark 已停止", completed: benchmarkSnapshot.completed, total: benchmarkSnapshot.total)
    }

    func runAgenticRLTrajectories() {
        guard let services else { return }
        agenticRLTask?.cancel()
        benchmarkTask?.cancel()
        let runID = UUID()
        agenticRLRunID = runID
        benchmarkRunID = nil
        benchmarkSnapshot = LuminaBenchmarkSnapshot()
        agenticRLSnapshot = LuminaAgenticRLSnapshot(state: .running, currentTask: "准备 200 条复杂轨迹任务", completed: 0, total: 200)
        agenticRLTask = Task { [weak self] in
            guard let self else { return }
            await services.waitUntilLoaded()
            guard self.agenticRLRunID == runID, !Task.isCancelled else { return }
            let runner = services.makeAgenticRLRunner()
            _ = await runner.run(taskCount: 200) { snapshot in
                guard self.agenticRLRunID == runID else { return }
                self.agenticRLSnapshot = snapshot
            }
            guard self.agenticRLRunID == runID, !Task.isCancelled else { return }
            self.agenticRLTask = nil
            await self.refreshStats()
            await self.refreshAuditRecords()
        }
    }

    func cancelAgenticRLTrajectories() {
        agenticRLRunID = nil
        agenticRLTask?.cancel()
        agenticRLTask = nil
        agenticRLSnapshot = LuminaAgenticRLSnapshot(state: .cancelled, currentTask: "Agentic RL 轨迹生成已停止", completed: agenticRLSnapshot.completed, total: agenticRLSnapshot.total)
    }

    func toggleVoiceInput() {
        voiceInput.toggle()
    }

    func clearAttachments() {
        attachments.removeAll()
    }

    func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func useVoiceTranscript() {
        guard var attachment = pendingVoiceAttachment else { return }
        let text = voiceTranscriptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                prompt = text
            } else {
                prompt += "\n\(text)"
            }
            attachment.transcript = text
            attachment.summary = text
        }
        attachments.append(attachment)
        pendingVoiceAttachment = nil
        voiceTranscriptDraft = ""
    }

    func retryVoiceInput() {
        pendingVoiceAttachment = nil
        voiceTranscriptDraft = ""
        voiceInput.toggle()
    }

    func dismissVoicePreview() {
        pendingVoiceAttachment = nil
        voiceTranscriptDraft = ""
    }

    func handleFileImport(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result else { return }
        for url in urls {
            let didStartAccessing = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccessing {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let localURL = copyIntoTemporaryStorage(url) ?? url
            attachments.append(AttachmentBuilder.make(from: localURL))
        }
    }

    func importSelectedPhotos() {
        let selectedItems = photoSelection
        guard !selectedItems.isEmpty else { return }
        Task {
            await importPhotos(selectedItems)
            photoSelection = []
        }
    }

    func refreshStats() async {
        guard let services else { return }
        let nextStats = await services.memoryStore.stats()
        stats = nextStats
        memoryViewModel.refreshFromParentStats(nextStats)
    }

    private func bindVoiceInput() {
        voiceInput.$state
            .sink { [weak self] state in
                self?.voiceState = state
            }
            .store(in: &cancellables)

        voiceInput.$transcript
            .sink { [weak self] transcript in
                self?.voiceTranscript = transcript
            }
            .store(in: &cancellables)

        voiceInput.$completedAttachment
            .compactMap { $0 }
            .sink { [weak self] attachment in
                guard let self else { return }
                pendingVoiceAttachment = attachment
                voiceTranscriptDraft = attachment.transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                _ = voiceInput.consumeCompletedAttachment()
            }
            .store(in: &cancellables)
    }

    private func bindConfirmation(services: AgentAppServices) {
        services.confirmation.$pending
            .sink { [weak self] request in
                self?.pendingConfirmation = request
            }
            .store(in: &cancellables)
    }

    private func bindAskUser(services: AgentAppServices) {
        services.askUser.$pending
            .sink { [weak self] request in
                self?.pendingAskUser = request
            }
            .store(in: &cancellables)

        services.askUser.$lastStatus
            .sink { [weak self] status in
                self?.askUserStatus = status
            }
            .store(in: &cancellables)
    }

    private func bindModelReadiness(services: AgentAppServices) {
        services.modelReadiness.$snapshot
            .sink { [weak self] snapshot in
                self?.modelReadiness = snapshot
            }
            .store(in: &cancellables)
    }

    private func startMessageDraftStream(services: AgentAppServices) {
        messageDraftTask = Task { [weak self] in
            for await draft in await services.messageDrafts.drafts() {
                guard !Task.isCancelled else { break }
                self?.pendingMessage = draft
            }
        }
    }

    private func refreshInitialData() async {
        guard let services else { return }
        await services.waitUntilLoaded()
        await refreshStats()
        await memoryViewModel.search()
        await refreshAuditRecords()
        await refreshHomeContent()
        await refreshStats()
    }

    private func runAgent() {
        guard let services else { return }
        services.beginSession()
        isRunning = true
        resultText = ""
        resultContent = []
        runSummary = nil
        timelineItems = [AgentRunTimelineItem(
            title: "准备本地运行",
            detail: "检查多模态输入、工具 schema 和端侧模型状态",
            systemImage: "bolt.horizontal.circle",
            status: .active
        )]
        activitySnapshot = LuminaAgentActivitySnapshot(
            state: .running,
            title: "准备本地执行",
            detail: "检查多模态输入、权限和本地模型状态",
            toolName: nil,
            progress: 0.08,
            isLocalOnly: true
        )
        activityCenter.start(snapshot: activitySnapshot)

        let content = makeRequestContent()
        runTask?.cancel()
        runTask = Task { [weak self] in
            guard let self else { return }
            await services.waitUntilLoaded()
            for await event in services.runStream(content: content) {
                guard !Task.isCancelled else { break }
                self.handleRunEvent(event)
            }
            self.isRunning = false
            guard !Task.isCancelled else { return }
            await self.refreshStats()
            await self.refreshAuditRecords()
            await self.refreshHomeContent()
            await self.refreshStats()
        }
    }

    private func cancelRun() {
        if let pendingAskUser {
            services?.askUser.cancel(requestID: pendingAskUser.id)
        }
        runTask?.cancel()
        runTask = nil
        isRunning = false
        timelineItems.append(AgentRunTimelineItem(
            title: "用户已停止",
            detail: "当前 stepGenerator/tool 调用已收到取消信号",
            systemImage: "stop.circle",
            status: .warning
        ))
        activitySnapshot = LuminaAgentActivitySnapshot(
            state: .cancelled,
            title: "已停止执行",
            detail: "本次本地任务已取消。",
            toolName: nil,
            progress: 1,
            isLocalOnly: true
        )
        activityCenter.finish(snapshot: activitySnapshot, shouldNotify: false)
    }

    private func makeRequestContent() -> [LuminaAgentContentPart] {
        var content: [LuminaAgentContentPart] = []
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrompt.isEmpty {
            content.append(.text(trimmedPrompt))
        }
        content.append(contentsOf: attachments.map { $0.contentPart() })
        return content
    }

    private func handleRunEvent(_ event: LuminaAgentRunEvent) {
        if let item = AgentRunEventPresenter.item(for: event) {
            upsertTimelineItem(item)
        }
        updateActivitySnapshot(for: event)

        switch event {
        case let .toolFinished(result):
            resultContent.append(contentsOf: result.content)
        case let .finalGenerated(markdown):
            resultText = markdown
        case let .finished(result):
            runSummary = LuminaAgentRunSummary(result: result)
            if resultText.isEmpty || shouldReplaceFallbackFinal(resultText) {
                resultText = render(result)
            }
            resultContent = result.toolResults.flatMap(\.content)
        default:
            break
        }
    }

    private func upsertTimelineItem(_ item: AgentRunTimelineItem) {
        guard let key = item.coalescingKey else {
            timelineItems.append(item)
            return
        }
        if let index = timelineItems.lastIndex(where: { $0.coalescingKey == key }) {
            var updated = item
            updated.id = timelineItems[index].id
            timelineItems[index] = updated
        } else {
            timelineItems.append(item)
        }
    }

    private func render(_ result: LuminaAgentRunResult) -> String {
        let completed = result.toolResults.filter { $0.status == .succeeded }.count
        var lines = ["## 执行结束", ""]
        if result.toolResults.isEmpty {
            if result.status == .succeeded {
                lines.append("没有需要执行的工具，Lumina 已完成本次处理。")
            } else {
                lines.append("本次执行没有完成。")
                lines.append("")
                lines.append(result.plan.summary)
            }
        } else {
            lines.append("已完成 \(completed)/\(result.toolResults.count) 个本地工具调用。")
            lines.append("")
            for toolResult in result.toolResults {
                lines.append("- \(friendlySummary(for: toolResult))")
            }
        }
        lines.append("")
        lines.append(String(format: "耗时：总 %.1fms，模型 %.1fms，工具 %.1fms。", result.timing.totalMilliseconds, result.timing.stepGenerationMilliseconds, result.timing.toolExecutionMilliseconds))
        if result.status != .succeeded {
            lines.append("")
            lines.append("你可以展开下方详情查看失败原因或重试。")
        }
        return lines.joined(separator: "\n")
    }

    private func shouldReplaceFallbackFinal(_ markdown: String) -> Bool {
        markdown.contains("results") ||
            markdown.contains("events") ||
            markdown.contains("ReAct Trace") ||
            markdown.contains("LuminaAgentRuntime.LuminaJSONValue")
    }

    private func friendlySummary(for result: LuminaToolResult) -> String {
        switch result.toolName {
        case "calendar.search":
            if case let .array(events)? = result.output["events"] {
                return events.isEmpty ? "没有找到匹配的日程。" : "找到 \(events.count) 个日程。"
            }
            return "日程查询已完成。"
        case "calendar.create":
            return result.output.string("title").map { "已创建日程：\($0)。" } ?? "日程创建请求已完成。"
        case "reminder.create":
            return result.output.string("title").map { "已创建提醒：\($0)。" } ?? "提醒创建请求已完成。"
        case "local.search":
            if case let .array(results)? = result.output["results"] {
                return results.isEmpty ? "没有找到匹配的本地记忆。" : "找到 \(results.count) 条本地记忆。"
            }
            return "本地检索已完成。"
        case "device.current_time":
            return result.output.string("localizedTime").map { "已读取本机时间：\($0)。" } ?? "已读取本机时间。"
        case "contacts.search":
            if case let .array(contacts)? = result.output["contacts"] {
                return contacts.isEmpty ? "没有找到匹配联系人。" : "找到 \(contacts.count) 个联系人。"
            }
            return "联系人查询已完成。"
        case "location.current":
            return result.output.string("summary") ?? "已读取当前位置。"
        case "notification.schedule":
            return result.output.string("title").map { "已安排本地通知：\($0)。" } ?? "本地通知已安排。"
        case "clipboard.read":
            return result.output.string("summary") ?? "已读取剪贴板。"
        case "file.save_note":
            return result.output.string("filename").map { "已保存文件：\($0)。" } ?? "文件已保存。"
        case "url.open":
            return result.output.string("url").map { "已打开：\($0)。" } ?? "打开请求已发送。"
        case "memory.ingest_text":
            return result.output.string("title").map { "已写入记忆：\($0)。" } ?? "记忆已写入。"
        case "ledger.search":
            if case let .array(transactions)? = result.output["transactions"] {
                return transactions.isEmpty ? "没有找到匹配账目。" : "找到 \(transactions.count) 条账目。"
            }
            return "账目查询已完成。"
        case "ask_user":
            if result.status == .cancelled {
                return "用户选择稍后再说，后续操作已暂停。"
            }
            if case let .array(answers)? = result.output["answers"] {
                return "已收到 \(answers.count) 个回答。"
            }
            return "已收到你的回答。"
        default:
            return result.errorMessage ?? "\(result.toolName) 已完成。"
        }
    }

    private func updateActivitySnapshot(for event: LuminaAgentRunEvent) {
        let baseProgress = min(0.92, max(0.12, Double(timelineItems.count) / 16.0))
        let snapshot: LuminaAgentActivitySnapshot
        switch event {
        case .stepGenerationStarted:
            snapshot = runningSnapshot(title: "正在理解请求", detail: "整理输入与可用工具", progress: baseProgress)
        case let .stepGenerationProgress(progress):
            let promptDetail = progress.promptTokens.map { "，prompt \($0) tokens" } ?? ""
            let sampledDetail = progress.outputTokens == 0 ? progress.sampledTokens.map { "，采样 \($0) tokens" } ?? "" : ""
            let outputDetail = progress.outputTokens > 0 ? "，输出 \(progress.outputTokens) tokens" : sampledDetail
            snapshot = runningSnapshot(
                title: "端侧模型生成中",
                detail: String(format: "第 %d 轮 ReAct，已运行 %.1fs%@%@", progress.iteration + 1, progress.elapsedMilliseconds / 1_000, promptDetail, outputDetail),
                progress: min(0.88, max(baseProgress, 0.18))
            )
        case let .thoughtGenerated(step):
            snapshot = runningSnapshot(title: "正在思考", detail: step.thought ?? "分析下一步动作", progress: baseProgress)
        case let .actionProposed(call):
            if call.toolName == "ask_user" {
                snapshot = LuminaAgentActivitySnapshot(
                    state: .waitingForConfirmation,
                    title: "等待你的选择",
                    detail: "Lumina 需要你补充信息后继续",
                    toolName: call.toolName,
                    progress: baseProgress,
                    isLocalOnly: true
                )
            } else {
                snapshot = runningSnapshot(title: "准备调用工具", detail: call.toolName, toolName: call.toolName, progress: baseProgress)
            }
        case let .observationCreated(observation):
            snapshot = runningSnapshot(title: "读取执行结果", detail: observation.summary, toolName: observation.toolName, progress: baseProgress)
        case .finalGenerated:
            snapshot = runningSnapshot(title: "正在整理回复", detail: "生成可读 Markdown 结果", progress: 0.94)
        case let .hookAnnotated(key, _):
            snapshot = runningSnapshot(title: "运行标注", detail: key, progress: baseProgress)
        case let .contextUpdated(context):
            snapshot = runningSnapshot(title: "上下文已更新", detail: "\(context.sections.count) 个片段", progress: baseProgress)
        case let .permissionChecked(call, decision):
            snapshot = runningSnapshot(title: "权限检查", detail: "\(call.toolName) \(decision)", toolName: call.toolName, progress: baseProgress)
        case let .confirmationRequired(call):
            snapshot = LuminaAgentActivitySnapshot(
                state: .waitingForConfirmation,
                title: "等待你的确认",
                detail: call.toolName,
                toolName: call.toolName,
                progress: baseProgress,
                isLocalOnly: true
            )
        case let .confirmationResolved(call, accepted):
            snapshot = runningSnapshot(title: accepted ? "已确认" : "已取消", detail: call.toolName, toolName: call.toolName, progress: baseProgress)
        case let .toolStarted(call):
            if call.toolName == "ask_user" {
                snapshot = LuminaAgentActivitySnapshot(
                    state: .waitingForConfirmation,
                    title: "等待你的选择",
                    detail: "Lumina 需要你补充信息后继续",
                    toolName: call.toolName,
                    progress: baseProgress,
                    isLocalOnly: true
                )
            } else {
                snapshot = runningSnapshot(title: "工具执行中", detail: call.toolName, toolName: call.toolName, progress: baseProgress)
            }
        case let .toolFinished(result):
            if result.toolName == "ask_user" {
                snapshot = runningSnapshot(
                    title: result.status == .cancelled ? "已暂停执行" : "已收到回答",
                    detail: result.status == .cancelled ? "用户选择稍后再说" : "继续执行本地 agent loop",
                    toolName: result.toolName,
                    progress: baseProgress
                )
            } else {
                snapshot = runningSnapshot(title: "工具已完成", detail: result.toolName, toolName: result.toolName, progress: baseProgress)
            }
        case let .rollbackStarted(call):
            snapshot = runningSnapshot(title: "正在回滚", detail: call.toolName, toolName: call.toolName, progress: baseProgress)
        case let .rollbackFinished(call, succeeded):
            snapshot = runningSnapshot(title: succeeded ? "回滚完成" : "回滚失败", detail: call.toolName, toolName: call.toolName, progress: baseProgress)
        case let .finished(result):
            let state: LuminaAgentActivityState = result.status == .succeeded ? .succeeded : .failed
            snapshot = LuminaAgentActivitySnapshot(
                state: state,
                title: result.status == .succeeded ? "执行已完成" : "执行未完成",
                detail: result.toolResults.isEmpty ? "结果已准备好" : "\(result.toolResults.filter { $0.status == .succeeded }.count)/\(result.toolResults.count) 个工具完成",
                toolName: nil,
                progress: 1,
                isLocalOnly: true
            )
        }
        activitySnapshot = snapshot
        if case .finished = event {
            activityCenter.finish(snapshot: snapshot, shouldNotify: scenePhase != .active)
        } else {
            activityCenter.update(snapshot: snapshot)
        }
    }

    private func runningSnapshot(title: String, detail: String, toolName: String? = nil, progress: Double) -> LuminaAgentActivitySnapshot {
        LuminaAgentActivitySnapshot(
            state: .running,
            title: title,
            detail: detail,
            toolName: toolName,
            progress: progress,
            isLocalOnly: true
        )
    }

    private func copyIntoTemporaryStorage(_ url: URL) -> URL? {
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(url.pathExtension)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                continue
            }
            let type = item.supportedContentTypes.first ?? .data
            let ext = type.preferredFilenameExtension ?? "bin"
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension(ext)
            do {
                try data.write(to: url, options: .atomic)
                attachments.append(MultimodalAttachment(
                    url: url,
                    filename: url.lastPathComponent,
                    contentTypeIdentifier: type.identifier,
                    byteCount: data.count,
                    summary: type.conforms(to: .image) ? "用户选择的图片" : "用户选择的视频"
                ))
            } catch {
                continue
            }
        }
    }

    private func refreshAuditRecords() async {
        guard let services else { return }
        auditRecords = await services.recentAuditRecords()
    }

    private func refreshHomeContent() async {
        guard let services else { return }
        let agent = HomePersonalizationAgent(
            memoryStore: services.memoryStore,
            auditLogReader: services.auditLogReader
        )
        let content = await agent.generate()
        homeContent = content
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !content.defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = content.defaultPrompt
        }
    }
}
