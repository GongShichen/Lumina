import LuminaAgentRuntime
import SwiftUI

struct AgentHomeView: View {
    @StateObject private var viewModel: AgentHomeViewModel
    @Environment(\.scenePhase) private var scenePhase
    private let services: AgentAppServices

    init(services: AgentAppServices) {
        self.services = services
        _viewModel = StateObject(wrappedValue: AgentHomeViewModel(services: services))
    }

    var body: some View {
        TabView(selection: $viewModel.selectedTab) {
            NavigationStack {
                AgentConsoleScreen(
                    prompt: $viewModel.prompt,
                    isRunning: viewModel.isRunning,
                    resultText: viewModel.resultText,
                    resultContent: viewModel.resultContent,
                    timelineItems: viewModel.timelineItems,
                    stats: viewModel.stats,
                    homeContent: viewModel.homeContent,
                    modelReadiness: viewModel.modelReadiness,
                    activitySnapshot: viewModel.activitySnapshot,
                    askUserStatus: viewModel.askUserStatus,
                    runSummary: viewModel.runSummary,
                    attachments: viewModel.attachments,
                    voiceState: viewModel.voiceState,
                    voiceTranscript: viewModel.voiceTranscript,
                    pendingVoiceAttachment: viewModel.pendingVoiceAttachment,
                    voiceTranscriptDraft: $viewModel.voiceTranscriptDraft,
                    photoSelection: $viewModel.photoSelection,
                    isFileImporterPresented: $viewModel.isFileImporterPresented,
                    runAction: viewModel.runAction,
                    rerunWithModel: viewModel.runAction,
                    voiceAction: viewModel.toggleVoiceInput,
                    useVoiceTranscript: viewModel.useVoiceTranscript,
                    retryVoiceInput: viewModel.retryVoiceInput,
                    dismissVoicePreview: viewModel.dismissVoicePreview,
                    clearAttachments: viewModel.clearAttachments,
                    removeAttachment: viewModel.removeAttachment
                )
            }
            .tag(LuminaTab.agent)
            .tabItem { Label("Today", systemImage: "sun.max.fill") }

            NavigationStack {
                PersonalMemoryScreen(viewModel: viewModel.memoryViewModel)
            }
            .tag(LuminaTab.memory)
            .tabItem { Label("Memory", systemImage: "brain.head.profile") }

            NavigationStack {
                KnowledgeBaseScreen(viewModel: viewModel.knowledgeViewModel)
            }
            .tag(LuminaTab.knowledge)
            .tabItem { Label("Knowledge", systemImage: "books.vertical.fill") }

            if LuminaFeatureFlags.showSettingsTab {
                NavigationStack {
                    LuminaSettingsScreen(
                        settings: services.remoteInferenceSettings,
                        localModelSelection: services.localModelSelection
                    )
                }
                .tag(LuminaTab.settings)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
            }

            if LuminaFeatureFlags.showRuntimeTab {
                NavigationStack {
                    RuntimeLabScreen()
                }
                .tag(LuminaTab.runtimeLab)
                .tabItem { Label("Runtime", systemImage: "point.3.connected.trianglepath.dotted") }
            }

            if LuminaFeatureFlags.showTrustTab {
                NavigationStack {
                    RuntimeStatusScreen(
                        stats: viewModel.stats,
                        modelReadiness: viewModel.modelReadiness,
                        benchmarkSnapshot: viewModel.benchmarkSnapshot,
                        runBenchmark: viewModel.runBenchmark,
                        cancelBenchmark: viewModel.cancelBenchmark
                    )
                }
                .tag(LuminaTab.runtime)
                .tabItem { Label("Trust", systemImage: "lock.shield.fill") }
            }
        }
        .tint(LuminaTheme.amber)
        .background(LuminaAppBackground())
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(.ultraThinMaterial, for: .tabBar)
        .overlay {
            if let request = viewModel.pendingAskUser {
                AskUserOverlay(request: request) { answers in
                    viewModel.submitAskUser(requestID: request.id, answers: answers)
                } cancel: {
                    viewModel.cancelAskUser(requestID: request.id)
                }
            }
        }
        .sheet(item: Binding(
            get: { viewModel.pendingConfirmation },
            set: { request in
                if request == nil, let pending = viewModel.pendingConfirmation {
                    viewModel.resolveConfirmation(id: pending.id, accepted: false)
                }
            }
        )) { request in
            ToolConfirmationSheet(request: request) { accepted in
                viewModel.resolveConfirmation(id: request.id, accepted: accepted)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: Binding(
            get: { viewModel.pendingMessage },
            set: { draft in
                if draft == nil, let pending = viewModel.pendingMessage {
                    viewModel.resolveMessage(id: pending.id, outcome: .cancelled)
                }
            }
        )) { draft in
            MessageComposeSheet(draft: draft) { outcome in
                viewModel.resolveMessage(id: draft.id, outcome: outcome)
            }
        }
        .fileImporter(
            isPresented: $viewModel.isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            viewModel.handleFileImport(result)
        }
        .onChange(of: viewModel.photoSelection) { _, _ in
            viewModel.importSelectedPhotos()
        }
        .onChange(of: viewModel.selectedTab) { _, newValue in
            if !newValue.isVisible {
                viewModel.selectedTab = newValue.visibleFallback
            }
        }
        .onChange(of: scenePhase) { _, phase in
            viewModel.updateScenePhase(phase)
        }
        .onAppear {
            viewModel.selectedTab = viewModel.selectedTab.visibleFallback
        }
        .task {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }
}

private struct LuminaSettingsScreen: View {
    @ObservedObject var settings: LuminaRemoteInferenceSettingsStore
    @ObservedObject var localModelSelection: LuminaLocalModelSelectionStore
    @State private var baseURL = ""
    @State private var model = ""
    @State private var apiKey = ""
    @State private var revealAPIKey = false
    @State private var saveStatus = ""
    @State private var saveStatusIsError = false

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    localModelPanel
                    remotePanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Settings")
        .onAppear(perform: loadCurrentSettings)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, LuminaTheme.ivory, LuminaTheme.softAmber],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 42
                        )
                    )
                    .shadow(color: LuminaTheme.amber.opacity(0.28), radius: 18, y: 8)
                Image(systemName: "gearshape.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Inference Settings")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text("留空使用本地模型；三项都填写后使用 OpenAI-compatible 流式 API。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var localModelPanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Local Model", subtitle: "原始权重会保留；切换后下一次端侧推理生效。")
                Picker("本地模型", selection: Binding(
                    get: { localModelSelection.selection },
                    set: { localModelSelection.select($0) }
                )) {
                    ForEach(LuminaLocalModelSelection.allCases) { selection in
                        Text(selection.shortLabel).tag(selection)
                    }
                }
                .pickerStyle(.segmented)
                Text("当前：\(localModelSelection.selection.displayName)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var remotePanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Remote API", subtitle: "Base URL 使用 /v1 形式，API key 仅保存到 Keychain。")
                settingsField(title: "Base URL", text: $baseURL, prompt: "https://example.com/v1", keyboard: .URL)
                settingsField(title: "Model", text: $model, prompt: "mimo-v2.5-pro", keyboard: .default)
                apiKeyField
                HStack(spacing: 10) {
                    Label(settings.modeDescription, systemImage: settings.currentConfiguration().isComplete ? "cloud.fill" : "desktopcomputer")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !saveStatus.isEmpty {
                        Text(saveStatus)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(saveStatusIsError ? Color.red : LuminaTheme.mint)
                    }
                }
                HStack(spacing: 10) {
                    Button {
                        do {
                            try settings.save(baseURL: baseURL, model: model, apiKey: apiKey)
                            apiKey = ""
                            revealAPIKey = false
                            saveStatusIsError = false
                            saveStatus = settings.currentConfiguration().isComplete ? "API key saved" : "Saved, missing API key"
                        } catch {
                            saveStatusIsError = true
                            saveStatus = error.localizedDescription
                        }
                    } label: {
                        Label("确认", systemImage: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(LuminaTheme.deepInk)

                    Button(role: .destructive) {
                        settings.clear()
                        loadCurrentSettings()
                        saveStatusIsError = false
                        saveStatus = "Cleared"
                    } label: {
                        Label("清空", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API Key")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Group {
                    if revealAPIKey {
                        TextField("sk-...", text: $apiKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(settings.hasAPIKey ? "***" : "", text: $apiKey, prompt: Text("***"))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                Button {
                    revealAPIKey.toggle()
                    if revealAPIKey && apiKey.isEmpty {
                        apiKey = settings.apiKeyForDisplay()
                    }
                } label: {
                    Image(systemName: revealAPIKey ? "eye.slash" : "eye")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(revealAPIKey ? "隐藏 API Key" : "显示 API Key")
            }
            .padding(10)
            .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(settings.hasAPIKey ? "API key saved in Keychain" : "API key missing")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(settings.hasAPIKey ? LuminaTheme.mint : .secondary)
        }
    }

    private func settingsField(
        title: String,
        text: Binding<String>,
        prompt: String,
        keyboard: UIKeyboardType
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(keyboard)
                .padding(10)
                .background(Color.white.opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func loadCurrentSettings() {
        baseURL = settings.baseURL
        model = settings.model
        apiKey = settings.hasAPIKey ? "" : ""
        revealAPIKey = false
    }
}

private struct RuntimeLabScreen: View {
    @StateObject private var viewModel = RuntimeLabViewModel()

    var body: some View {
        ZStack {
            LuminaAppBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    statusPanel
                    actionPanel
                    resultsPanel
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 26)
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Runtime")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.white, LuminaTheme.ivory, LuminaTheme.aqua.opacity(0.42)],
                            center: .topLeading,
                            startRadius: 4,
                            endRadius: 42
                        )
                    )
                    .shadow(color: LuminaTheme.aqua.opacity(0.22), radius: 18, y: 8)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(LuminaTheme.deepInk)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 3) {
                Text("Runtime Lab")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text("真实运行 Core/C ABI 能力：replay、live tool、session、checkpoint、state、guardrail、hook 与 observability sink。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var statusPanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Run Status", subtitle: "这个页面直接调用 Runtime，不经过 Benchmark harness。")
                HStack(spacing: 10) {
                    Label(viewModel.statusTitle, systemImage: viewModel.statusIcon)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(viewModel.statusColor)
                    Spacer()
                    if viewModel.isRunning {
                        ProgressView()
                    }
                }
                if !viewModel.summary.isEmpty {
                    Text(viewModel.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var actionPanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Runtime Checks", subtitle: "每一项都来自同一条运行链路产生的返回值、checkpoint 或 sink。")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    ForEach(viewModel.checks) { check in
                        RuntimeLabCheckTile(check: check)
                    }
                }
                Button {
                    viewModel.run()
                } label: {
                    Label(viewModel.isRunning ? "正在运行" : "运行 Runtime 测试", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(LuminaTheme.deepInk)
                .disabled(viewModel.isRunning)
            }
        }
    }

    private var resultsPanel: some View {
        LuminaPanel(padding: 16) {
            VStack(alignment: .leading, spacing: 14) {
                LuminaSectionHeader(title: "Evidence", subtitle: "保留关键 JSON 摘要，便于确认不是 UI 假状态。")
                ForEach(viewModel.evidence) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.title)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(LuminaTheme.ink)
                        Text(item.body)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color.white.opacity(0.46), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

private struct RuntimeLabCheckTile: View {
    let check: RuntimeLabCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: check.icon)
                .font(.headline.weight(.bold))
                .foregroundStyle(check.color)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(check.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(LuminaTheme.ink)
                Text(check.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(Color.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct RuntimeLabCheck: Identifiable {
    enum State {
        case pending
        case passed
        case failed
    }

    let id: String
    let title: String
    let detail: String
    let state: State

    var icon: String {
        switch state {
        case .pending: return "circle"
        case .passed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch state {
        case .pending: return .secondary
        case .passed: return LuminaTheme.mint
        case .failed: return Color.red
        }
    }
}

private struct RuntimeLabEvidence: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

@MainActor
private final class RuntimeLabViewModel: ObservableObject {
    @Published var isRunning = false
    @Published var statusTitle = "未运行"
    @Published var statusIcon = "circle"
    @Published var statusColor: Color = .secondary
    @Published var summary = "点击按钮后会创建 Runtime，并真实执行一条 replay 驱动的 live tool run。"
    @Published var checks: [RuntimeLabCheck] = RuntimeLabViewModel.initialChecks()
    @Published var evidence: [RuntimeLabEvidence] = [
        RuntimeLabEvidence(title: "waiting", body: "Runtime test has not run yet.")
    ]

    private var task: Task<Void, Never>?

    func run() {
        guard !isRunning else { return }
        isRunning = true
        statusTitle = "运行中"
        statusIcon = "arrow.triangle.2.circlepath"
        statusColor = LuminaTheme.amber
        summary = "正在执行 Core replay、tool callback、session state/checkpoint、hook、guardrail 和 sink 验证。"
        checks = Self.initialChecks()
        evidence = [RuntimeLabEvidence(title: "started", body: ISO8601DateFormatter().string(from: Date()))]
        task = Task { [weak self] in
            await self?.runSuite()
        }
    }

    private func runSuite() async {
        do {
            let report = try await RuntimeLabSuite().run()
            checks = report.checks
            evidence = report.evidence
            statusTitle = report.passed ? "全部通过" : "存在失败"
            statusIcon = report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
            statusColor = report.passed ? LuminaTheme.mint : Color.red
            summary = report.summary
        } catch {
            checks = Self.initialChecks(failedReason: error.localizedDescription)
            evidence = [RuntimeLabEvidence(title: "error", body: error.localizedDescription)]
            statusTitle = "运行失败"
            statusIcon = "xmark.octagon.fill"
            statusColor = Color.red
            summary = error.localizedDescription
        }
        isRunning = false
    }

    private static func initialChecks(failedReason: String? = nil) -> [RuntimeLabCheck] {
        let state: RuntimeLabCheck.State = failedReason == nil ? .pending : .failed
        let detail = failedReason ?? "waiting"
        return [
            RuntimeLabCheck(id: "provider", title: "External Provider", detail: detail, state: state),
            RuntimeLabCheck(id: "replay", title: "Replay + Live Tool", detail: detail, state: state),
            RuntimeLabCheck(id: "guardrail", title: "Guardrail", detail: detail, state: state),
            RuntimeLabCheck(id: "hook", title: "Runtime Hook", detail: detail, state: state),
            RuntimeLabCheck(id: "session", title: "Session State", detail: detail, state: state),
            RuntimeLabCheck(id: "checkpoint", title: "Checkpoint", detail: detail, state: state),
            RuntimeLabCheck(id: "observability", title: "Observability", detail: detail, state: state)
        ]
    }
}

private struct RuntimeLabReport {
    let passed: Bool
    let summary: String
    let checks: [RuntimeLabCheck]
    let evidence: [RuntimeLabEvidence]
}

private struct RuntimeLabSuite {
    func run() async throws -> RuntimeLabReport {
        let signals = RuntimeLabSignals()
        let sink = RuntimeLabObservabilitySink()
        let request = LuminaAgentRequest(
            systemInstructions: "Exercise Runtime Lab.",
            text: "Use runtime.echo and return result.",
            metadata: ["runtime_lab": .bool(true)]
        )
        let runtime = makeRuntime(signals: signals, sink: sink)
        let providerResult = runtime.registerExternalToolProvider(providerJSON: providerJSON)
        let topLevelResult = await runtime.runReplay(request: request, replayJSON: replayJSON)

        let sessionRuntime = makeRuntime(signals: signals, sink: sink)
        _ = sessionRuntime.registerExternalToolProvider(providerJSON: providerJSON)
        guard let session = sessionRuntime.createSession(request: request) else {
            throw RuntimeLabError("failed to create runtime session")
        }
        let stateSet = session.setState(scope: "session", key: "runtime_lab", valueJSON: #"{"enabled":true,"source":"app"}"#)
        let stateGet = session.getState(scope: "session", key: "runtime_lab")
        let sessionResultJSON = await session.run(replayJSON: replayJSON)
        let checkpoint = session.exportCheckpoint()
        let snapshot = session.snapshot()
        let restored = sessionRuntime.createSession(checkpointJSON: checkpoint)
        let restoredSnapshot = restored?.snapshot() ?? "{}"

        try await Task.sleep(nanoseconds: 150_000_000)
        let observability = await sink.snapshot()
        let signalSnapshot = await signals.snapshot()

        let providerPassed = providerResult.contains(#""ok":true"#) && providerResult.contains(#""registered_tools":1"#)
        let replayPassed = topLevelResult.status == .succeeded
            && topLevelResult.toolResults.contains { $0.toolName == "runtime.echo" && $0.status == .succeeded }
            && topLevelResult.plan.summary.contains("Runtime lab complete")
            && signalSnapshot.liveToolCalls > 0
        let guardrailPassed = signalSnapshot.inputGuardrails > 0
            && signalSnapshot.toolInputGuardrails > 0
            && signalSnapshot.toolOutputGuardrails > 0
            && signalSnapshot.resultGuardrails > 0
            && topLevelResult.plan.summary.contains("[guardrail-ok]")
        let hookPassed = signalSnapshot.hookEvents > 0
        let sessionPassed = stateSet.contains(#""ok":true"#)
            && stateGet.contains(#""enabled":true"#)
            && sessionResultJSON.contains(#""status":"succeeded""#)
        let checkpointPassed = checkpoint.contains(#""session_id""#)
            && checkpoint.contains(#""runtime_state""#)
            && restored != nil
            && restoredSnapshot.contains(#""session_id""#)
        let observabilityPassed = observability.traces > 0
            && observability.metrics > 0
            && observability.spans > 0
            && observability.samplePayload.contains(#""session_id""#)
            && observability.samplePayload.contains(#""run_id""#)

        let checks = [
            check("provider", "External Provider", "registered via Core C ABI", providerPassed),
            check("replay", "Replay + Live Tool", "\(signalSnapshot.liveToolCalls) live tool callback(s)", replayPassed),
            check("guardrail", "Guardrail", "\(signalSnapshot.totalGuardrails) guardrail callback(s)", guardrailPassed),
            check("hook", "Runtime Hook", "\(signalSnapshot.hookEvents) hook callback(s)", hookPassed),
            check("session", "Session State", "set/get + session run", sessionPassed),
            check("checkpoint", "Checkpoint", "export + restore session", checkpointPassed),
            check("observability", "Observability", "\(observability.traces) traces, \(observability.metrics) metrics, \(observability.spans) spans", observabilityPassed)
        ]
        let passed = checks.allSatisfy { $0.state == .passed }
        let evidence = [
            RuntimeLabEvidence(title: "provider", body: excerpt(providerResult)),
            RuntimeLabEvidence(title: "result", body: excerpt(topLevelResult.plan.summary)),
            RuntimeLabEvidence(title: "state", body: excerpt(stateGet)),
            RuntimeLabEvidence(title: "checkpoint", body: excerpt(checkpoint)),
            RuntimeLabEvidence(title: "snapshot", body: excerpt(snapshot)),
            RuntimeLabEvidence(title: "observability", body: excerpt(observability.samplePayload))
        ]
        let summary = passed
            ? "Runtime Core 能力已通过 app 内真实链路验证。"
            : "Runtime Lab 有检查未通过，请查看下方 evidence。"
        return RuntimeLabReport(passed: passed, summary: summary, checks: checks, evidence: evidence)
    }

    private func makeRuntime(signals: RuntimeLabSignals, sink: RuntimeLabObservabilitySink) -> LuminaAgentRuntime {
        LuminaAgentRuntime(
            tools: [runtimeEchoTool(signals: signals)],
            stepGenerator: LuminaUnavailableReActStepGenerator(),
            configuration: LuminaAgentRuntimeConfiguration(
                maximumToolCalls: 10,
                maximumReActIterations: 4,
                maximumObservationCharacters: 2_000,
                contextWindowTokens: 4_096,
                maxOutputTokens: 512,
                reservedOutputTokens: 128,
                toolResultTokenBudget: 1_024,
                compactThresholdTokens: 3_200,
                maximumCompactFailures: 1,
                maximumConsecutiveReasoningSteps: 2,
                maximumConsecutiveReplayObservations: 2,
                stopOnToolFailure: false,
                rollbackFailedSideEffects: false,
                emitVerboseEvents: true,
                preservedStepsAfterCompaction: 4,
                toolSchemaDisclosureProfile: .compact,
                toolLoadingMode: "direct",
                checkpointPolicy: .onStep
            ),
            permissionGate: LuminaDefaultPermissionGate(),
            confirmationCoordinator: LuminaAlwaysConfirmCoordinator(),
            hooks: [RuntimeLabHook(signals: signals)],
            observabilitySinks: LuminaRuntimeObservabilitySinks(
                trace: sink,
                metrics: sink,
                span: sink,
                policy: LuminaRuntimeObservabilityPolicy(detailLevel: .debug, includeModelRawOutputSummary: true)
            ),
            guardrails: LuminaRuntimeGuardrails(
                input: [RuntimeLabInputGuardrail(signals: signals)],
                toolInput: [RuntimeLabToolInputGuardrail(signals: signals)],
                toolOutput: [RuntimeLabToolOutputGuardrail(signals: signals)],
                result: [RuntimeLabResultGuardrail(signals: signals)]
            )
        )
    }

    private func runtimeEchoTool(signals: RuntimeLabSignals) -> AnyLuminaAgentTool {
        let schema = LuminaToolSchema(
            name: "runtime.echo",
            description: "Echoes text for Runtime Lab verification.",
            parameters: [
                LuminaToolParameterSchema(name: "message", type: .string, description: "Message to echo.")
            ],
            sideEffect: .readOnly,
            sensitivity: .low,
            concurrencySafe: true
        )
        return AnyLuminaAgentTool(schema: schema) { arguments, _ in
            await signals.recordLiveTool()
            let message = arguments["message"]?.stringValue ?? ""
            return LuminaToolResult(
                callID: UUID(),
                toolName: "runtime.echo",
                status: .succeeded,
                output: ["echo": .string(message)],
                content: [.text("echo: \(message)")]
            )
        }
    }

    private var providerJSON: String {
        #"""
        {
          "provider_id":"runtime-lab",
          "namespace":"runtime",
          "allowed_tools":["echo"],
          "schemas":[
            {
              "name":"echo",
              "description":"Provider-discovered echo tool for Runtime Lab.",
              "version":1,
              "parameters":[{"name":"message","type":"string","description":"Message to echo.","required":true}],
              "sideEffect":"readOnly",
              "sensitivity":"low",
              "acceptedInputModalities":["text","structuredData"],
              "outputModalities":["text","structuredData"],
              "requiresUserInteraction":false,
              "destructive":false,
              "concurrencySafe":true
            }
          ]
        }
        """#
    }

    private var replayJSON: String {
        #"""
        {
          "mode":"model",
          "model_outputs":[
            {
              "step":{
                "schema_version":"1.0",
                "step_id":"runtime-lab-tool",
                "type":"tool_use",
                "thinking":"Exercise a live app tool through the runtime.",
                "tool_name":"runtime.echo",
                "parameters":{"message":"hello from runtime lab"},
                "requires_confirmation":false,
                "requires_followup":true
              }
            },
            {
              "step":{
                "schema_version":"1.0",
                "step_id":"runtime-lab-result",
                "type":"result",
                "thinking":"The tool returned successfully.",
                "content":"## Runtime lab complete",
                "completed":true,
                "requires_followup":false
              }
            }
          ]
        }
        """#
    }

    private func check(_ id: String, _ title: String, _ detail: String, _ passed: Bool) -> RuntimeLabCheck {
        RuntimeLabCheck(id: id, title: title, detail: detail, state: passed ? .passed : .failed)
    }

    private func excerpt(_ value: String, limit: Int = 900) -> String {
        if value.count <= limit { return value }
        return String(value.prefix(limit)) + "..."
    }
}

private struct RuntimeLabError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

private struct RuntimeLabSignalSnapshot {
    let inputGuardrails: Int
    let toolInputGuardrails: Int
    let toolOutputGuardrails: Int
    let resultGuardrails: Int
    let hookEvents: Int
    let liveToolCalls: Int

    var totalGuardrails: Int {
        inputGuardrails + toolInputGuardrails + toolOutputGuardrails + resultGuardrails
    }
}

private actor RuntimeLabSignals {
    private var inputGuardrails = 0
    private var toolInputGuardrails = 0
    private var toolOutputGuardrails = 0
    private var resultGuardrails = 0
    private var hookEvents = 0
    private var liveToolCalls = 0

    func recordInputGuardrail() { inputGuardrails += 1 }
    func recordToolInputGuardrail() { toolInputGuardrails += 1 }
    func recordToolOutputGuardrail() { toolOutputGuardrails += 1 }
    func recordResultGuardrail() { resultGuardrails += 1 }
    func recordHookEvent() { hookEvents += 1 }
    func recordLiveTool() { liveToolCalls += 1 }

    func snapshot() -> RuntimeLabSignalSnapshot {
        RuntimeLabSignalSnapshot(
            inputGuardrails: inputGuardrails,
            toolInputGuardrails: toolInputGuardrails,
            toolOutputGuardrails: toolOutputGuardrails,
            resultGuardrails: resultGuardrails,
            hookEvents: hookEvents,
            liveToolCalls: liveToolCalls
        )
    }
}

private struct RuntimeLabInputGuardrail: LuminaInputGuardrail {
    let signals: RuntimeLabSignals

    func evaluate(request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaAgentRequest> {
        await signals.recordInputGuardrail()
        return .allow
    }
}

private struct RuntimeLabToolInputGuardrail: LuminaToolInputGuardrail {
    let signals: RuntimeLabSignals

    func evaluate(call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaToolCall> {
        await signals.recordToolInputGuardrail()
        return .allow
    }
}

private struct RuntimeLabToolOutputGuardrail: LuminaToolOutputGuardrail {
    let signals: RuntimeLabSignals

    func evaluate(result: LuminaToolResult, call: LuminaToolCall, schema: LuminaToolSchema, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<LuminaToolResult> {
        await signals.recordToolOutputGuardrail()
        return .allow
    }
}

private struct RuntimeLabResultGuardrail: LuminaResultGuardrail {
    let signals: RuntimeLabSignals

    func evaluate(markdown: String, request: LuminaAgentRequest) async -> LuminaGuardrailDecision<String> {
        await signals.recordResultGuardrail()
        return .rewrite(markdown + "\n\n[guardrail-ok]")
    }
}

private struct RuntimeLabHook: LuminaMatchingAgentRuntimeHook {
    let signals: RuntimeLabSignals
    let matcher = LuminaAgentRuntimeHookMatcher(events: [.beforeTool], toolNamePatterns: ["runtime.echo"])

    func handle(event: LuminaAgentRuntimeHookEvent, context: LuminaAgentRuntimeHookContext) async throws -> [LuminaAgentRuntimeHookDirective] {
        await signals.recordHookEvent()
        return [.proceed]
    }
}

private struct RuntimeLabObservabilitySnapshot {
    let traces: Int
    let metrics: Int
    let spans: Int
    let samplePayload: String
}

private actor RuntimeLabObservabilitySink: LuminaRuntimeTraceSink, LuminaRuntimeMetricsSink, LuminaRuntimeSpanSink {
    private var traces: [String] = []
    private var metrics: [String] = []
    private var spans: [String] = []

    func recordTrace(_ recordJSON: String) async {
        traces.append(recordJSON)
    }

    func recordMetric(_ metricJSON: String) async {
        metrics.append(metricJSON)
    }

    func recordSpan(_ spanJSON: String) async {
        spans.append(spanJSON)
    }

    func snapshot() -> RuntimeLabObservabilitySnapshot {
        RuntimeLabObservabilitySnapshot(
            traces: traces.count,
            metrics: metrics.count,
            spans: spans.count,
            samplePayload: spans.first ?? traces.first ?? metrics.first ?? "{}"
        )
    }
}
